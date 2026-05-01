# New host partitioning runbook

How to partition a fresh disk for a NixOS host that follows the same
layout as `pb-x1`. Adapted from the live layout on this machine
(2026-05-01); update if the substrate diverges.

> **Tip:** the manual partition + mount + install sequence in this
> document is also encoded as `scripts/host-setup.sh`. Modes are
> selected by an explicit flag (mode flags are mutually exclusive):
>
> ```sh
> sudo scripts/host-setup.sh /dev/nvme0n1 --partition   # DESTRUCTIVE: wipe + format only (no mount)
> sudo scripts/host-setup.sh /dev/nvme0n1 --mount       # mount existing layout under /mnt (idempotent)
> sudo scripts/host-setup.sh /dev/nvme0n1               # same as --mount (default when disk is given)
> sudo scripts/host-setup.sh --unmount                  # release /mnt tree cleanly
>
> # then, in the cloned flake repo:
> sudo scripts/host-setup.sh --install pb-t480          # gen hwconfig + git add + verify + nixos-install
> ```
>
> The `--install` mode regenerates `hosts/<hostname>/hardware-configuration.nix`,
> `git add`s it (the AGENTS.md gotcha that bites everyone exactly once),
> verifies via `nix eval --refresh` that the resolved root device UUID
> matches what's actually mounted at `/mnt`, and only then runs
> `nixos-install`. It refuses to proceed if `/mnt/boot` isn't a vfat
> mountpoint — the failure mode that left earlier installs booting
> into a kernel waiting for the all-zeros sentinel UUID.
>
> Aborting at the `--install` confirm prompt cleanly reverts the
> staged hwconfig and removes the temporary backup file, so the repo
> ends bit-identical to its pre-invocation state.
>
> Use the script during install troubleshooting; use the manual steps
> below if you want to learn what each command does or you've diverged
> from the canonical layout.

This is the layout flake-modules/battery.nix assumes for the
hibernate swapfile: a single btrfs filesystem with a `root`
subvolume, and `/swap/swapfile` provisioned by NixOS into it (CoW
disabled). If you change the layout (separate swap partition,
zfs, ext4, encrypted, etc.) you will need to revisit battery.nix
and the host bridge's `boot.resumeDevice` / `boot.kernelParams`.

## Reference layout (pb-x1)

```
/dev/nvme0n1                         976 GiB total NVMe
├─ p1  vfat (ESP)        1024 MiB    /boot
└─ p2  btrfs            ~975 GiB     <one filesystem, multiple subvolumes>
        ├─ subvol=root              → /
        ├─ subvol=home              → /home
        └─ subvol=nix               → /nix   (with /nix/store ro-bind)
```

Key choices:
- **GPT + UEFI** (no BIOS / MBR). `boot.loader.systemd-boot` in the
  host bridge.
- **One big btrfs partition** for everything except ESP. Subvolumes
  give you snapshot boundaries without partition juggling.
- **1 GiB ESP** is generous; systemd-boot with multiple kernel
  generations comfortably fits in 512 MiB but 1 GiB leaves headroom
  for firmware updates (fwupd dumps capsule files into the ESP).
- **No swap partition.** Hibernate uses a btrfs swapfile at
  `/swap/swapfile`, provisioned automatically by `flake-modules/
  battery.nix` based on `battery.swapSizeGiB`. Don't allocate swap
  here.
- **No LUKS** on pb-x1 today. If you want full-disk encryption,
  use LUKS2 on `p2` and put btrfs inside it; the rest of the
  layout doesn't change.

## Prerequisites

Boot the NixOS minimal installer ISO. You should be at a root
shell (or `sudo -i`).

Identify the target disk. **Triple-check this** — the wrong device
name will obliterate something you cared about.

```sh
lsblk -d -o NAME,SIZE,MODEL,TRAN
# pick the one matching your laptop's NVMe / SATA SSD.
# replace nvme0n1 below with the actual name.
DISK=/dev/nvme0n1
```

If the disk has any prior content you don't need, wipe the
partition table and any old btrfs / LUKS signatures so leftover
metadata doesn't confuse subsequent steps:

```sh
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
```

## Partition

GPT, two partitions: 1 GiB ESP + remainder.

```sh
parted "$DISK" -- mklabel gpt
parted "$DISK" -- mkpart ESP fat32 1MiB 1025MiB
parted "$DISK" -- set 1 esp on
parted "$DISK" -- mkpart primary btrfs 1025MiB 100%
```

Result (verify with `parted "$DISK" unit MiB print`):

```
Number  Start    End        Size       File system  Name     Flags
 1      1.00MiB  1025MiB    1024MiB    fat32        ESP      boot, esp
 2      1025MiB  <end>      <rest>     btrfs        primary
```

The `1MiB` start aligns p1 to flash erase blocks; `parted` will
warn if it can't, fix the offset before continuing.

Pick the partition device names. NVMe inserts a `p`:

```sh
P1="${DISK}p1"   # ESP                     (e.g. /dev/nvme0n1p1)
P2="${DISK}p2"   # btrfs root              (e.g. /dev/nvme0n1p2)
# For SATA the names are /dev/sda1 and /dev/sda2 — set DISK=/dev/sda
# and use ${DISK}1 / ${DISK}2 instead.
```

## Format

ESP (label `BOOT` matches pb-x1 — purely cosmetic, but consistent):

```sh
mkfs.fat -F 32 -n BOOT "$P1"
```

btrfs (no label needed — we mount by-uuid). Add `-f` only if
re-running over an existing filesystem:

```sh
mkfs.btrfs "$P2"
```

## Create subvolumes

Mount the bare btrfs filesystem temporarily so we can carve out
subvolumes, then unmount.

```sh
mount "$P2" /mnt
btrfs subvolume create /mnt/root
btrfs subvolume create /mnt/home
btrfs subvolume create /mnt/nix
umount /mnt
```

Why subvolumes (not directories): each subvolume is an independent
snapshot/quota domain. You can `btrfs subvolume snapshot /home …`
without copying anything, roll back `/` independently of `/home`,
and exclude `/nix` from snapshot rotations (it's reproducible from
the flake — no point in snapshotting the store).

## Mount in install order

NixOS expects everything under `/mnt` before `nixos-install` runs.
Mount options match what `nixos-generate-config` will write into
`hardware-configuration.nix`:

```sh
mount -o subvol=root,compress=zstd,noatime "$P2" /mnt

mkdir -p /mnt/{boot,home,nix}
mount -o subvol=home,compress=zstd,noatime "$P2" /mnt/home
mount -o subvol=nix,compress=zstd,noatime  "$P2" /mnt/nix
mount "$P1"                                       /mnt/boot
```

Notes:
- `compress=zstd` is optional; saves space on `/nix` especially.
  pb-x1 didn't enable it — adding it makes the layout diverge from
  pb-x1's `hardware-configuration.nix`. Skip if you want byte
  parity with pb-x1.
- `noatime` is optional but a sensible default on SSDs.
- The swapfile at `/swap/swapfile` is **not** created here.
  flake-modules/battery.nix provisions it on first activation via
  `swapDevices`; the parent dir gets `chattr +C` automatically.

## Generate hardware-configuration.nix

```sh
nixos-generate-config --root /mnt
```

This produces:
- `/mnt/etc/nixos/configuration.nix` — discard / overwrite, this
  flake doesn't use it.
- `/mnt/etc/nixos/hardware-configuration.nix` — **keep**. Copy
  this into the flake repo at
  `hosts/<hostname>/hardware-configuration.nix` and `git add` it
  before the first build.

The file should contain `fileSystems."/"`, `fileSystems."/home"`,
`fileSystems."/nix"`, `fileSystems."/boot"` blocks each pointing
at `/dev/disk/by-uuid/<uuid>` (NOT `/dev/nvme0n1pN` — UUIDs
survive disk reshuffles).

## Capture the resume UUID for hibernate

flake-modules/battery.nix needs `boot.resumeDevice` to point at the
btrfs partition holding the swapfile (which is the same partition
as `/`):

```sh
blkid -s UUID -o value $(findmnt -no SOURCE /mnt)
# e.g. e2ac9790-a670-4602-ba38-6aaee856b73c
```

Set it in `flake-modules/hosts/<hostname>.nix`:

```nix
battery = {
  # …
  resumeDevice = "/dev/disk/by-uuid/e2ac9790-a670-4602-ba38-6aaee856b73c";
};
```

The `battery-resume-offset` systemd unit will print the right
`boot.kernelParams = [ "resume_offset=NNN" ];` line on first boot
once the swapfile exists; add that to the host bridge afterward
and `nixos-rebuild switch` once more for hibernate-resume to
actually work.

## First install

From the installer, with the flake repo cloned somewhere reachable
(e.g. `/mnt/persist/nixos` or pulled fresh):

```sh
nixos-install --flake /path/to/nixos#<hostname> --no-root-password
# Set passwords post-install with `passwd <user>` from the booted
# system. The host bridge sets `initialPassword = "changeme"` for
# every account; rotate immediately on first login.
```

Reboot. On first successful boot:

1. `passwd p` (and any other users) to replace the
   `initialPassword = "changeme"` literals.
2. Watch `journalctl -u battery-resume-offset` for the offset
   nag; copy that `resume_offset=NNN` value into the host bridge
   and rebuild + reboot once for hibernate to actually resume.
3. Confirm charge thresholds are honored:
   `cat /sys/class/power_supply/BAT*/charge_control_end_threshold`
   should match `battery.chargeStopThreshold`.

## Pitfalls

- **Forgetting to `git add` hardware-configuration.nix.** The
  flake build only sees git-tracked files. A correctly-generated
  but untracked hwconfig produces the placeholder behavior, which
  trips the `NIXOS_ALLOW_PLACEHOLDER` assertion.
- **Wrong root device in the placeholder.** If you copy the
  generated hwconfig but it still shows the all-zeros sentinel
  UUID at `/`, you copied from a stale generation. Re-run
  `nixos-generate-config --show-hardware-config` and check.
- **swapDevices in hardware-configuration.nix.** The generator
  emits `swapDevices = [ ];` because we didn't create a swap
  partition. **Leave it that way** — battery.nix appends the
  swapfile definition. Do NOT delete the empty list (you'd lose
  the file-level definition shadow that lets battery.nix's
  swapDevices win the merge).
- **btrfs `compress=zstd` retroactively.** Adding `compress=zstd`
  later only compresses newly-written data; existing files stay
  uncompressed until rewritten. If you want compression, set it
  at install time.
- **systemd-boot fails to install.** Almost always
  `boot.loader.efi.canTouchEfiVariables = true` failing in a VM
  or on hardware that locks NVRAM. Set it to `false` and run
  `bootctl install --no-variables` manually if needed.
