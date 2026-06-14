# TrueNAS-side setup for restic-over-SFTP backups

One-time prep on the NAS so every NixOS host in this flake can push
backups to it via `flake.modules.nixos.backup`. Tested on TrueNAS
SCALE; the shell side is plain OpenSSH so the recipe is the same
on any Linux/BSD SSH server.

## Threat model

- **Endpoint spoofing** (hostile network resolves `nas.lan` to an
  attacker) is defeated client-side: each host pins the NAS host
  key in `/persist/etc/ssh-restic/restic_known_hosts` and uses
  `StrictHostKeyChecking=yes`. Nothing on the NAS mitigates this.
- **Repository content secrecy** is provided by restic's symmetric
  encryption with the per-host repo password
  (`/persist/etc/restic/host.pass`). The NAS only sees ciphertext.
- **Cross-host isolation** is by per-host repo password, not NAS
  filesystem ACLs. The shared `restic-backup` UNIX user can read
  every host's repo (that's how `scripts/seed-from-host.sh` works);
  it just can't decrypt without the matching password.

## Steps

### 1. Create the `restic-backup` user

**Credentials → Local Users → Add**:

- Username: `restic-backup`
- Shell: `/sbin/nologin`
- Home directory: `/mnt/zrust/backup/restic`
- Disable password (we'll allow password auth at the sshd layer
  for one-time `ssh-copy-id` bootstrap; the account itself never
  needs a password)
- Auxiliary groups: none

Then create + chown the backup root:

```sh
install -d -m 0700 -o restic-backup -g restic-backup \
    /mnt/zrust/backup/restic
install -d -m 0700 -o restic-backup -g restic-backup \
    /mnt/zrust/backup/restic/.ssh
install -m 0600 -o restic-backup -g restic-backup /dev/null \
    /mnt/zrust/backup/restic/.ssh/authorized_keys
```

Adjust `/mnt/zrust/backup/restic` to your pool layout; whatever
path you pick goes into the host bridge's `backup.repoBasePath`.

### 2. sshd Match block

**System → SSH → Auxiliary Parameters** (appended to
`/etc/ssh/sshd_config`):

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
either a valid pubkey or the account password as a complete chain.
Password auth is needed during the one-time `ssh-copy-id` bootstrap
that `scripts/init-backup.sh` performs (sshd has nothing else to
authenticate the operator with before the host's pubkey is on the
NAS). After bootstrap every backup uses pubkey. The blast radius
is bounded: the Match block applies only to `restic-backup`, the
shell is `internal-sftp` jailed to the backup root, and every
object is symmetric-encrypted before it leaves the client.

Restart SSH from **System → Services → SSH → Restart** after
saving.

### 3. Per-host bootstrap

For each new host, after `nixos-anywhere` finishes and the host
boots, the operator runs `scripts/init-backup.sh` on the host:

1. Prompts for the repo password (paste from password manager).
2. Generates a per-host ed25519 SSH key.
3. Runs `ssh-copy-id restic-backup@nas.lan` — prompts the NAS
   account password once.
4. Pins the NAS host key into the host's known_hosts.
5. Either `restic init` (fresh host) or detects an existing repo
   and skips init (reinstall — the host's previous backups are
   still there, just keep using them).

After that the daily timer takes over.

## Verifying

```sh
sudo systemctl start restic-backups-host.service
sudo journalctl -u restic-backups-host.service -e
```

Common failures:

- `Host key verification failed` — re-pin via
  `ssh-keyscan -t ed25519 nas.lan | sudo tee
  /persist/etc/ssh-restic/restic_known_hosts`.
- `Permission denied (publickey)` — confirm the host's pubkey is in
  `/mnt/zrust/backup/restic/.ssh/authorized_keys` on the NAS.
