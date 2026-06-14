# TrueNAS-side setup for restic-over-SFTP backups

One-time prep on the NAS so every NixOS host in this flake can push
backups to it via `flake.modules.nixos.backup`. Tested on TrueNAS
SCALE 24.10 (Electric Eel); the shell side is plain OpenSSH so older
SCALE / CORE should also work — the UI paths are what differ.

## Threat model recap

* Endpoint spoofing on a hostile network resolving `nas.lan` to an
  attacker is defeated client-side by the per-host pinned host key
  (`/persist/etc/ssh-restic/restic_known_hosts` +
  `StrictHostKeyChecking=yes`). Nothing on the NAS side mitigates
  this; it's purely a client posture.
* Repository content secrecy is provided by restic's symmetric
  encryption with the per-host repo password
  (`/persist/etc/restic/host.pass`). The NAS only sees ciphertext.
* Cross-host data isolation is **per-host repo password**, NOT NAS
  filesystem ACLs. The shared `restic-backup` UNIX user is allowed
  to read every host's repo (that's how cross-host seeding works);
  it just can't decrypt without the matching password.
* SSH should be chrooted to a single dataset via `internal-sftp`
  ForceCommand so the `restic-backup` user can't poke at anything
  else on the NAS even if its key leaks.

## Dataset layout

The pieces below live under a backup-purposed dataset on whatever
pool you already use for bulk storage. The example throughout this
runbook is `zrust/backup` (mountpoint `/mnt/zrust/backup`) with a
new `restic` subdirectory used as the `restic-backup` user's home;
adjust to your pool.

* Pool/dataset: `zrust/backup` (already exists in your setup)
* New subdirectory: `/mnt/zrust/backup/restic` — `restic-backup`'s
  home AND the parent of every host's repo
* Compression: lz4 (or off — restic already deflates; lz4 is cheap
  enough to leave on)
* Quota: optional but recommended (e.g. 1 TiB) so a runaway client
  can't fill the pool
* Snapshot policy: 0 (let restic own retention; ZFS snapshots of an
  already-deduped repo are wasted space)

Per-host subdirectories under `/mnt/zrust/backup/restic/<hostname>`
are created by the FIRST backup of each host because the egghead
bridge sets `services.restic.backups.host.initialize = true`. You
do NOT need to pre-create them.

`repoBasePath` in each host bridge (and the default in
`flake-modules/backup.nix`) is the absolute NAS path
`/mnt/zrust/backup/restic`. Repo URLs end up as
`sftp:restic-backup@nas.lan:/mnt/zrust/backup/restic/<hostname>`.

## SSH user

Create the unprivileged `restic-backup` UNIX user (TrueNAS UI:
**Credentials → Local Users → Add**):

* Username: `restic-backup`
* Full Name: `Restic SFTP service account`
* Shell: `/sbin/nologin` (or whatever the equivalent is in your
  build; the ForceCommand below makes the shell choice moot)
* Home directory: `/mnt/zrust/backup/restic` (so `~restic-backup`
  is the same as the backup root)
* Create home directory: **off** if you already created it below;
  otherwise let TrueNAS create it
* Disable password (auth is key-only)
* Auxiliary groups: none

Then create the directory and chown the backup root so this user
can write into it:

```sh
install -d -m 0700 -o restic-backup -g restic-backup /mnt/zrust/backup/restic
```

(0700 keeps non-`restic-backup` users from snooping the encrypted
repo blobs; nothing else needs to read them.)

## sshd Match block

Add to TrueNAS UI **System → SSH → Auxiliary Parameters** (the
contents of this box are appended to `/etc/ssh/sshd_config`):

```
Match User restic-backup
    ForceCommand internal-sftp -d /mnt/zrust/backup/restic
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    PasswordAuthentication yes
    AuthenticationMethods publickey password
```

`AuthenticationMethods publickey password` means sshd accepts
**either** a valid pubkey **or** the account password as a complete
chain. Password auth is needed during the one-time `ssh-copy-id`
bootstrap (sshd has nothing else to authenticate the operator with
before the host's pubkey is on the NAS). After the key is installed
every backup run uses pubkey; password is just a fallback for future
re-bootstraps. The blast radius is bounded: this Match block applies
only to the `restic-backup` user, that user's shell is
`internal-sftp` jailed to `/mnt/zrust/backup/restic`, and every
object stored there is symmetric-encrypted with the per-host repo
password before it ever leaves the client.

If you want to lock things down once all hosts are bootstrapped,
flip back to `PasswordAuthentication no` /
`AuthenticationMethods publickey` — at the cost of needing to paste
pubkeys manually for any future host added to the fleet.

No `ChrootDirectory` — we rely on `ForceCommand internal-sftp` plus
the 0700 ownership on `/mnt/zrust/backup/restic` to keep the
restic-backup user in its lane. Without a chroot the absolute path
the client sends matches the absolute path on the NAS, which makes
URLs (`sftp:restic-backup@nas.lan:/mnt/zrust/backup/restic/<host>`)
match what `ls` shows.

If you'd rather harden with chroot: `ChrootDirectory
/mnt/zrust/backup/restic` requires the chroot dir AND every
ancestor to be root-owned 0755 (incompatible with the 0700 above),
and the repo URLs would become chroot-relative (e.g.
`sftp:...:/<hostname>`). That's documented as an option but not the
default in this flake — every script and module default assumes
no-chroot.

Restart the SSH service from the TrueNAS UI **System → Services →
SSH → Restart** after saving.

## authorized_keys

Without chroot, sshd reads `~restic-backup/.ssh/authorized_keys`
directly from the user's home (`/mnt/zrust/backup/restic/.ssh/`).
Easiest is to let TrueNAS / `ssh-copy-id` manage it there:

```sh
install -d -m 0700 -o restic-backup -g restic-backup /mnt/zrust/backup/restic/.ssh
install -m 0600 -o restic-backup -g restic-backup /dev/null /mnt/zrust/backup/restic/.ssh/authorized_keys
```

When the operator runs `scripts/preimpermanence-backup.sh` or
egghead-finishes a fresh install, `ssh-copy-id` (driven by the
one-time NAS password prompt) appends the host's pubkey here. You
can also paste manually from the post-install summary
(`/persist/etc/ssh-restic/restic_ed25519.pub` on the installed
host).

Optional restriction (recommended): prefix each line with
`restrict,command="internal-sftp"` to belt-and-suspenders the
ForceCommand block, so even a Match misconfig can't grant shell.

## Verifying from a client

From any NixOS host that's been through egghead with backup turned
on (this also runs automatically the first time the systemd timer
fires; running it manually just lets you see errors immediately):

```sh
sudo systemctl start restic-backups-host.service
sudo journalctl -u restic-backups-host.service -e
```

Expected sequence on first run:

1. `backup-wait-for-ac` exits 0 (on AC or no AC node).
2. `backupPrepareCommand` creates `/run/restic-snapshots/persist`.
3. `restic init` succeeds (creates `<repoBasePath>/<hostname>/`).
4. `restic backup` reports something like
   `processed N files, X.Y MiB in 30s`.
5. `restic forget --keep-* --prune` reports the new retention state.
6. `backupCleanupCommand` deletes the btrfs snapshot.

If step 3 fails with "Host key verification failed", the
`/persist/etc/ssh-restic/restic_known_hosts` file is empty or stale
— re-run `ssh-keyscan -t ed25519,rsa nas.lan | sudo tee
/persist/etc/ssh-restic/restic_known_hosts`. If step 3 fails with
"Permission denied (publickey)", verify the host's pubkey is on the
NAS in the right `authorized_keys` location and that the Match
block's `AuthorizedKeysFile` actually points there.

## Re-installing a host (preserving the repo)

The egghead `IS_REINSTALL=yes` flow asks for the existing repo
password and writes it to `/persist/etc/restic/host.pass` instead of
generating a fresh one. The NAS side needs no changes; the new
install reuses the same repo URL (it's keyed on `<hostname>`) and
the same SSH user, just with a freshly generated per-host SSH key
(which the operator pastes onto the NAS the same way they did the
first time around).
