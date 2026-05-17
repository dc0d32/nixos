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
| Swap partlabel            | none (swapfile-based)     | `disk-main-swap` (own GPT partition, type 8200) |
| Btrfs FS label            | varies / unset            | `nixos`                                         |
| Btrfs subvols (top level) | `root`, `home`, `nix`     | `root`, `home`, `nix`, `snapshots`              |
| Swap                      | `/swap/swapfile` (inside root subvol, `chattr +C`-ed by hand) + per-host `resume_offset` | dedicated swap partition; disko sets `boot.resumeDevice` automatically — no `resume_offset` needed |

After the bridge migration, `nix eval
.#nixosConfigurations.<host>.config.fileSystems` references
`/dev/disk/by-partlabel/disk-main-{ESP,nixos}` and mountpoint
`/.snapshots`; `nix eval … config.swapDevices` references
`/dev/disk/by-partlabel/disk-main-swap`. If the running disk has none
of those partlabels and only three of the four subvols, the next
initrd hangs forever in the "waiting for device …" loop because the
by-partlabel udev symlinks never appear and the subvol mounts fail.

pb-x1 hit this trap on first rebuild after the disko switch. After
unblocking by hand, we automated the dance.

## Affected hosts

- **pb-x1** — partlabels/subvols/btrfs-label migrated in-place on
  2026-05-17 (initial pass). Swap partition reshape is still pending
  on this host because the bridge switched from btrfs swapfile to a
  dedicated swap partition after the initial migration; running the
  script again will plan that reshape.
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

# 3. If the plan includes a RESHAPE line for the swap partition, the
#    --yes run will prompt for the target disk's MODEL and SIZE
#    (typed-back confirmation). Have those handy.

# 4. If the plan looks right, execute:
sudo ./scripts/disko-migrate.sh <hostname> --yes

# 5. Stage the new generation but DO NOT switch (defers activation to
#    next boot so the current generation remains as rollback):
sudo nixos-rebuild boot --flake .#<hostname>

# 6. Reboot:
sudo reboot
```

No `resume_offset` capture or follow-up rebuild needed — the swap
partition's stable `/dev/disk/by-partlabel/disk-main-swap` path is
written into `boot.resumeDevice` by disko at eval time.

If the new generation hangs at boot, force-reboot and pick the
previous generation from the systemd-boot menu. Caveat: if the
reshape phase ran, the partition table has changed and any OLD
generation that referenced the disk by PARTUUID will also fail. The
btrfs FS data is preserved (we shrunk it inside the original
partition before sgdisk reshaped the boundary), but you'll need a
NixOS live ISO with this flake to debug — or just `nixos-rebuild
switch` from the live env against the new (post-reshape) layout.

### What the script refuses to touch

- **LUKS hosts** (`boot.initrd.luks.devices` non-empty in the
  evaluated config). In-place `luksFormat` + reshape is way more
  risky than reinstalling via egghead. v1 limitation.
- **Multi-disk hosts** (`fileSystems.*` references more than one
  parent block device). None of today's hosts do this; the check is
  defensive.
- **Reshape on a disk where the root partition isn't last.** If
  something sits between the nixos partition and end-of-disk, we
  can't grow swap into the gap without relocating that something. The
  script bails with a clear error in that case.
- **Hosts where `hostname` ≠ the arg you passed.** Defends against
  running the migration on the wrong machine.

## Fallback: hand-rolled migration

If the script can't handle a host (e.g. weird LUKS or multi-disk
layout) and you still want to migrate without reinstalling, the
recipe used on pb-x1 by hand (adapt the disk paths + swap size):

```sh
HOST=pb-x1   # adjust
DISK=/dev/nvme0n1
ROOTPART=/dev/nvme0n1p2
ROOTPARTN=2
SWAP_SIZE=32G       # match the bridge's diskoLayouts.bare-metal swapSize

# Phase 1: GPT partlabels (metadata-only, reversible).
sudo sgdisk -c 1:disk-main-ESP -c $ROOTPARTN:disk-main-nixos $DISK
sudo partprobe $DISK

# Phase 2: btrfs filesystem label.
sudo btrfs filesystem label / nixos

# Phase 3: create missing top-level subvols (snapshots; pre-disko
# already had root/home/nix).
sudo mkdir -p /mnt/top
sudo mount -o subvolid=5 $ROOTPART /mnt/top
sudo btrfs subvolume create /mnt/top/snapshots
sudo umount /mnt/top
sudo rmdir /mnt/top

# Phase 4: retire any pre-migration swapfile.
sudo swapoff /swap/swapfile 2>/dev/null || true
sudo rm -f /swap/swapfile
# Leave the /swap directory alone — battery.nix no longer manages it
# and aggressive deletion of dangling subvols is not worth the risk.

# Phase 5: reshape — shrink btrfs, shrink nixos partition, add swap
# partition at end. Tooling: btrfs-progs + sgdisk.

# 5a. Compute shrink delta = swap_size + 256MiB margin (in bytes).
SHRINK_BYTES=$(( 32*1024*1024*1024 + 256*1024*1024 ))   # 32G + 256M

# 5b. Stop any active swap on this disk so it doesn't anchor the FS.
sudo swapoff -a

# 5c. Shrink the btrfs FS by that delta.
sudo btrfs filesystem resize -${SHRINK_BYTES} /

# 5d. Save the old nixos partition's first sector — we'll re-create
#     it with the same start so existing FS data stays at the same
#     on-disk offsets. Then delete it.
OLD_START=$(sudo sgdisk -i $ROOTPARTN $DISK \
            | awk '/First sector:/ {print $3; exit}')
sudo sgdisk -d $ROOTPARTN $DISK

# 5e. Create swap partition at the END of the disk (sgdisk's negative
#     start = N bytes from end).
sudo sgdisk -n 0:-${SWAP_SIZE}:0 -c 0:disk-main-swap -t 0:8200 $DISK
sudo partprobe $DISK; sleep 1

# 5f. Read back swap's first sector and re-create nixos partition.
SWAP_PARTN=$(sudo sgdisk -p $DISK | awk '/disk-main-swap/ {print $1; exit}')
SWAP_START=$(sudo sgdisk -i $SWAP_PARTN $DISK \
             | awk '/First sector:/ {print $3; exit}')
NIXOS_END=$(( SWAP_START - 1 ))
sudo sgdisk -n $ROOTPARTN:$OLD_START:$NIXOS_END \
            -c $ROOTPARTN:disk-main-nixos -t $ROOTPARTN:8300 $DISK

# 5g. mkswap on the new partition.
sudo partprobe $DISK; sleep 1
sudo mkswap /dev/disk/by-partlabel/disk-main-swap

# Phase 6: stage new generation (DON'T switch) and reboot.
sudo nixos-rebuild boot --flake .#$HOST
sudo reboot
```

`/swap/swapfile` doesn't grow back: the new bridge has no swapfile
code path — `boot.resumeDevice` and `swapDevices` are populated by
disko's swap content type directly from the partition.

### Resize-later note

The user's intuition that swap "should be resizable on the fly with
btrfs commands" is half-right: btrfs can resize subvols and the
underlying FS, but the swap partition is its own raw block partition
that btrfs doesn't manage. To grow/shrink swap later: `swapoff
/dev/disk/by-partlabel/disk-main-swap`, sgdisk-reshape the partition,
`mkswap` again, `swapon`. Or just edit the bridge's `swapSize =
"<N>G";` and re-run this script (the dry-run will print the planned
reshape; --yes will execute it).

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
