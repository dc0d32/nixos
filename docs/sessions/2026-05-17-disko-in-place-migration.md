# 2026-05-17 — In-place disko migration for pre-disko hosts

## Why

The disko switchover (commit `c24521a`) flipped every bare-metal host
bridge from hand-rolled `fileSystems.*` blocks in
`hosts/<name>/hardware-configuration.nix` to a synthesized
`fileSystems.*` set produced by
`config.flake.lib.diskoLayouts.bare-metal { disk = …; }`. New hosts
provisioned via `egghead` or `host-setup.sh --install` get the
canonical layout end-to-end. Hosts that already existed before the
switchover do not.

The synthesized layout assumes:

| Property                  | Pre-disko install         | Canonical disko layout                          |
| ------------------------- | ------------------------- | ----------------------------------------------- |
| ESP partlabel             | usually empty / `BOOT`    | `disk-main-ESP`                                 |
| Root partlabel            | usually empty             | `disk-main-nixos`                               |
| Btrfs FS label            | varies / unset            | `nixos`                                         |
| Btrfs subvols (top level) | `root`, `home`, `nix`     | `root`, `home`, `nix`, `swap`, `snapshots`     |
| Swapfile                  | `/swap/swapfile` (inside root subvol, `chattr +C`-ed by hand) | `/swap/swapfile` on its own `swap` subvol mounted `nodatacow` |

After the bridge migration, `nix eval
.#nixosConfigurations.<host>.config.fileSystems` references
`/dev/disk/by-partlabel/disk-main-{ESP,nixos}` and mountpoints
`/swap`, `/.snapshots`. If the running disk has none of those
partlabels and only three of the five subvols, the next initrd
hangs forever in the "waiting for device …" loop because the
by-partlabel udev symlinks never appear and the subvol mounts fail.

pb-x1 hit this trap on first rebuild after the disko switch. After
unblocking by hand, we automated the dance.

## Affected hosts

- **pb-x1** — already migrated by hand on 2026-05-17. Marker:
  `boot.kernelParams = [ "resume_offset=10162202" ];` in the bridge.
- **pb-t480** — bridge was disko-migrated in `c24521a`. If the
  physical laptop hasn't been `nixos-rebuild switch`-ed since that
  commit, it's in the trap. Run `disko-migrate.sh` on it.
- **Any other host installed before `c24521a`.** The wizard
  (`egghead`) didn't exist before that commit, so any pre-existing
  install on this flake is a candidate.

m-pc is a placeholder (never been provisioned); it will be installed
via egghead from scratch, no migration needed.

## Recommended path: `scripts/disko-migrate.sh`

```sh
# 1. On the target host, pull latest and dry-run the migration:
cd ~/nixos
git pull
sudo ./scripts/disko-migrate.sh <hostname>

# 2. Read the plan it prints. If the host is already on the canonical
#    layout the script exits 0 with "nothing to do".

# 3. If the plan looks right, execute:
sudo ./scripts/disko-migrate.sh <hostname> --yes

# 4. Stage the new generation but DO NOT switch (defers activation to
#    next boot so the current generation remains as rollback):
sudo nixos-rebuild boot --flake .#<hostname>

# 5. Reboot:
sudo reboot

# 6. On first boot, capture the resume_offset for hibernate-resume:
journalctl -u battery-resume-offset.service -b

# 7. Edit the host bridge to pin it:
#       boot.kernelParams = [ "resume_offset=<N>" ];
git add flake-modules/hosts/<hostname>.nix
sudo nixos-rebuild switch --flake .#<hostname>
```

If the new generation hangs at boot, force-reboot and pick the
previous generation from the systemd-boot menu — the script does
nothing destructive (sgdisk label edits are reversible metadata,
btrfs subvol creation is additive, and the only deletion is the old
swapfile *after* `swapoff`).

### What the script refuses to touch

- **LUKS hosts** (`boot.initrd.luks.devices` non-empty in the
  evaluated config). In-place `luksFormat` would have to drain and
  re-shape the entire data partition; way more risky than reinstalling
  via egghead. v1 limitation, will revisit if needed.
- **Multi-disk hosts** (`fileSystems.*` references more than one
  parent block device). None of today's hosts do this; the check is
  defensive.
- **Hosts where `hostname` ≠ the arg you passed.** Defends against
  running the migration on the wrong machine.

## Fallback: hand-rolled migration

If the script can't handle a host (e.g. weird LUKS or multi-disk
layout) and you still want to migrate without reinstalling, the
5-phase recipe used on pb-x1 by hand:

```sh
HOST=pb-x1   # adjust
DISK=/dev/nvme0n1
ROOTPART=/dev/nvme0n1p2
ESPPART=/dev/nvme0n1p1

# Phase 1: GPT partlabels (metadata-only, reversible).
sudo sgdisk -c 1:disk-main-ESP -c 2:disk-main-nixos $DISK
sudo partprobe $DISK

# Phase 2: btrfs filesystem label.
sudo btrfs filesystem label / nixos

# Phase 3: create missing top-level subvols.
sudo mkdir -p /mnt/top
sudo mount -o subvolid=5 $ROOTPART /mnt/top
sudo btrfs subvolume create /mnt/top/swap
sudo chattr +C /mnt/top/swap
sudo btrfs subvolume create /mnt/top/snapshots
sudo umount /mnt/top
sudo rmdir /mnt/top

# Phase 4: retire pre-migration swapfile (if it exists under the
# root subvol's /swap/swapfile).
sudo swapoff /swap/swapfile
sudo rm /swap/swapfile
sudo rmdir /swap

# Phase 5: stage new generation (DON'T switch) and reboot.
sudo nixos-rebuild boot --flake .#$HOST
sudo reboot

# After first boot, pin the resume offset:
journalctl -u battery-resume-offset.service -b
# Edit flake-modules/hosts/$HOST.nix:
#   boot.kernelParams = [ "resume_offset=<N>" ];
sudo nixos-rebuild switch --flake .#$HOST
```

## Why `nixos-rebuild boot`, not `switch`

`switch` activates the new generation immediately as the running
system *and* makes it the default boot entry. If activation half-runs
and then hangs (e.g. on a wedged service), you're left with neither
generation fully ready.

`boot` only writes the new entry into the bootloader; the current
running generation is untouched. If the new generation hangs at
initrd, you reboot to systemd-boot, pick the prior generation, and
you're back to a known-good state. This matters especially on
pre-disko hosts where the synthesized fileSystems set might still
diverge from reality even after the script claims to be done (e.g. if
a partition number changed between bridge edits).

## Why we keep the script in `scripts/`, not `flake-modules/`

The script is operational tooling — useful precisely when a host is
in a state where `nixos-rebuild` won't complete. Wrapping it in
`pkgs.writeShellApplication` and shipping it through a feature module
means the only way to update it is `nixos-rebuild switch`, which is
the operation the script exists to enable. `scripts/disko-migrate.sh`
runs against a checked-out repo with system-installed `nix`, `jq`,
`sgdisk`, `btrfs-progs` — all already present on any NixOS install
that imports the disko bridge.

## Retirement

This script becomes dead code once every host the flake supports has
been provisioned through `egghead` / `host-setup.sh --install` on the
disko code path — i.e. there are no more pre-disko installs anywhere
in the fleet. Delete `scripts/disko-migrate.sh` and this doc together
when that day arrives.
