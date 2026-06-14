# Host migration: live host → impermanence + declarative backup

End-to-end playbook for nuking a pre-impermanence host and bringing
it back up on the new impermanence + restic stack **without losing
non-Nix-managed state** (Bitwarden vault, Chrome profile, FreeCAD
prefs, WiFi keys, Bluetooth pairings, etc.).

Run this once per host. Order:

```
TrueNAS one-time setup                  ──┐
                                          ├──► applies to ALL hosts
pubkey installed manually OR via         │
ssh-copy-id from each host                ──┘

(per host, repeat)
  preimpermanence-backup.sh                ──► snapshots live state to NAS
  stash repo password + ssh key off-host   ──► password manager / USB
  egghead refresh with IS_REINSTALL=yes    ──► wipes disk, reinstalls
  preimpermanence-restore.sh               ──► pulls snapshot into /persist
  reboot
```

Each phase is recoverable: at any point before the egghead wipe the
operator can abort and the source host is untouched.

## 0. One-time NAS setup

Follow `docs/runbooks/truenas-restic.md` once. End state:

* `/mnt/zrust/backup/restic` exists, owned by `restic-backup:restic-backup`,
  mode 0700.
* User `restic-backup` exists with `/sbin/nologin` shell, no password.
* sshd has a `Match User restic-backup` block with `ForceCommand
  internal-sftp -d /mnt/zrust/backup/restic`, `AllowTcpForwarding no`,
  `PasswordAuthentication no`, `AuthenticationMethods publickey`.
* `~restic-backup/.ssh/authorized_keys` exists (empty is fine —
  `preimpermanence-backup.sh` will `ssh-copy-id` into it).
* SSH service restarted.

Verify from any client:

```sh
ssh -o BatchMode=no restic-backup@nas.lan
# should prompt for password (proves user exists + sshd Match works)
# Ctrl-C out — we don't actually want a shell
```

## 1. Pre-impermanence backup of each live host

Per host. Needs network reachability to `nas.lan` (or whatever
`--nas-host` points at) and root.

```sh
sudo ./scripts/preimpermanence-backup.sh
```

First run:

* Generates ed25519 SSH key at `/var/lib/preimpermanence-backup/id_ed25519`.
* `ssh-keyscan`-pins the NAS host key into `known_hosts`.
* Prompts for the **NAS password ONCE** (via `ssh-copy-id`) to install
  the pubkey. After that all communication is key-auth, no password.
* Generates a random restic repo password.
* `restic init` against `sftp:restic-backup@nas.lan:/mnt/zrust/backup/restic/<hostname>`.
* `restic backup --tag preimpermanence --tag preimpermanence-<datetime>`
  of every path the impermanence module will later persist (see
  `flake-modules/impermanence.nix:295-351` for the canonical list)
  PLUS every normal user's `/home/<login>`. Junk excludes (`.cache`,
  `node_modules`, browser caches, Trash, etc.) are baked in.

Subsequent runs reuse the same key + password + repo, producing an
additional `preimpermanence-<datetime>` snapshot. Useful as a final
"day-of-the-nuke" sync — operator might do one run a week before
the rebuild and another right before powering down.

### Stash secrets

The script prints a big banner at the end with:

* The repo URL (`sftp:restic-backup@nas.lan:/mnt/zrust/backup/restic/<host>`)
* The repo password (contents of `/var/lib/preimpermanence-backup/repo.pass`)
* The SSH private key path (`/var/lib/preimpermanence-backup/id_ed25519`)
* The pubkey (already installed on NAS)

**Copy the password and the private key to a password manager or USB
stick now.** Both are inside the soon-to-be-wiped filesystem. There
is no way to recover snapshots without the password — restic
encryption is symmetric.

### Optional: cross-host pre-flight

Operator can verify the snapshot is browseable from any other machine:

```sh
RESTIC_REPOSITORY=sftp:restic-backup@nas.lan:/mnt/zrust/backup/restic/pb-x1 \
RESTIC_PASSWORD_FILE=/path/to/stashed/repo.pass \
RESTIC_SFTP_COMMAND="ssh -i /path/to/stashed/id_ed25519 -o UserKnownHostsFile=/path/to/stashed/known_hosts restic-backup@nas.lan -s sftp" \
  restic snapshots
```

If this lists at least one `preimpermanence`-tagged snapshot, you're
safe to proceed to the wipe.

## 2. Egghead refresh with `IS_REINSTALL=yes`

Boot the NixOS installer ISO, clone the flake, run egghead. When the
wizard reaches the backup step, answer:

* `IS_REINSTALL=yes`
* Paste the **same** repo password from the stash.
* Paste the **same** SSH private key contents from the stash (the
  wizard writes them to `/persist/etc/ssh-restic/restic_ed25519` and
  `/persist/etc/restic/host.pass` in the new install).

After egghead finishes `nixos-install`, do NOT reboot yet — go to
step 3 first. Reboot now and the first-boot impermanence rollback
will start fresh with no restored state (it's recoverable — just
restore after the first boot — but doing it pre-reboot avoids the
need for the recovery-root login).

If you DID reboot first, no harm done: log in as root (using the
recovery password egghead echoed) and run step 3 from there.

## 3. Restore preimpermanence snapshot into /persist

From the installer environment (or from a recovery-root session
after first boot), with `/mnt` still mounted on the new btrfs root
(or with `/persist` directly accessible):

```sh
# from inside the installer, /persist is at /mnt/persist:
sudo ./scripts/preimpermanence-restore.sh --target /mnt/persist

# from inside the running host:
sudo preimpermanence-restore.sh
```

By default this:

* Reads the repo URL from `/persist/etc/restic/host.repo` (egghead
  populates this), or falls back to scraping the embedded URL out
  of the system-installed `backup-restore` wrapper.
* Reads the password from `/persist/etc/restic/host.pass`.
* Reads the SSH key from `/persist/etc/ssh-restic/restic_ed25519`.
* Picks the latest `preimpermanence`-tagged snapshot for the current
  hostname.
* `restic restore --target /persist` (or whatever `--target` was
  passed). Snapshot paths like `/home/p/.config/Bitwarden` land at
  `/persist/home/p/.config/Bitwarden` — exactly where the new
  impermanence module's `users.p.directories` bind mount expects.
* `chown -R <uid>:<gid>` each `/persist/home/<login>` to handle uid
  changes between the old and new install (pass `--no-chown` to
  skip).
* Explicitly excludes `/etc/machine-id` and `/etc/ssh/ssh_host_*` so
  the new install keeps its freshly-minted host identity (pass
  `--include-host-identity` to override).

## 4. Reboot + verify

```sh
sudo reboot
```

After reboot:

* `journalctl -b 0 -u rollback.service` — confirms the
  impermanence rollback ran cleanly.
* `ls /home/<you>/.config` — should show every dotfile from the old
  install.
* `nmcli connection show` — WiFi networks should be present.
* `bluetoothctl devices` — paired devices should be there.
* `systemctl --user status` — your user services should be running.

Run a fresh "real" backup to validate the declarative module:

```sh
sudo systemctl start restic-backups-host.service
sudo journalctl -u restic-backups-host.service -e
```

Should produce a new snapshot tagged `auto`, sibling to the
preimpermanence ones.

## 5. Cleanup (after the dust settles)

Once you trust every migrated host has been running for a few
weeks AND you've successfully restored from an `auto`-tagged
snapshot at least once:

```sh
RESTIC_REPOSITORY=... RESTIC_PASSWORD_FILE=... \
  restic forget --tag preimpermanence --prune
```

This drops the migration-era snapshots and frees the NAS-side
storage they occupied.

## Troubleshooting

* **ssh-copy-id says "All keys were skipped because they already
  exist on the remote system"** — fine, key is already installed.
  The subsequent `ssh ... true` test should pass.
* **`restic init` says "config file already exists"** — fine, repo
  was initialized by a previous run. Just keep going.
* **Restore writes files but bind-mounts on next boot don't show
  them** — check that `/persist` is on the same filesystem as the
  bind targets and that `fileSystems."/persist".neededForBoot =
  true` is set. Verify with `findmnt /persist` after first boot.
* **`du` warns about permission errors on /var/log** — those are
  read by root during the backup anyway; the warnings just affect
  the size estimate, not the snapshot contents.
* **Cross-host seeding wanted (e.g. m-pc taking pb-x1's home)** —
  use `preimpermanence-restore.sh --hostname pb-x1 --repo
  sftp:restic-backup@nas.lan:/mnt/zrust/backup/restic/pb-x1 --password-file
  /path/to/stashed/pb-x1-repo.pass --include /home/p`. Be careful
  about uid/gid mapping; passing `--no-chown` and doing the chown
  by hand may be needed if the source user doesn't exist on the
  destination.
