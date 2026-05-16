# New host partitioning runbook

Disk layout is declarative now. The previous manual
`wipefs → sgdisk → parted → mkfs → mount` runbook is retired in
favour of disko (`flake-modules/disko.nix`) plus a single
`host-setup.sh --install` invocation.

## TL;DR

From a NixOS live USB / installer ISO, after cloning this flake
into the live env:

```sh
sudo ./scripts/host-setup.sh --install <hostname>
```

This:

1. Regenerates `hosts/<hostname>/hardware-configuration.nix` from
   the live installer kernel (with `--no-filesystems` — disko owns
   `fileSystems.*` and `swapDevices`).
2. `git add`s it (flake builds only see git-tracked files).
3. Reads `config.disko.devices.disk.main.device` from the host bridge,
   shows the target disk with `lsblk`, and demands a literal `YES`.
4. Builds and runs `config.system.build.diskoScript` — wipes the
   disk, writes partitions, formats filesystems, mounts everything
   under `/mnt`.
5. Runs `nixos-install` with niri.cachix.org substituters preloaded.
6. Bootstraps each HM-enabled user's home-manager profile and seeds
   `~/nixos` from `https://github.com/dc0d32/nixos` (opt-out via
   `--no-clone-sources` / `--no-install-hm`).

Pass `--disk </dev/...>` to override the disko-declared disk path
(useful when the same host config is reused across machines with
different physical disks).

## Layouts

Defined in `flake-modules/disko.nix` and instantiated per host via
`config.flake.lib.diskoLayouts.{bare-metal,vm}`:

**bare-metal** (pb-x1, pb-t480, m-pc):

```
p1: 1 MiB   bios-boot (ef02)         partlabel=disk-main-BIOS
p2: 1 GiB   vfat ESP                 partlabel=disk-main-ESP        → /boot
p3: rest    btrfs                    partlabel=disk-main-nixos
              subvol=root                                             → /
              subvol=nix                                              → /nix
              subvol=home                                             → /home
              subvol=swap        (nodatacow, noatime)                 → /swap
              subvol=snapshots   (nodatacow, noatime)                 → /.snapshots
```

Hybrid bios-boot + ESP lets the same layout boot on BIOS firmware
(m-pc Compaq SFF, via grub) and UEFI (laptops, via systemd-boot)
without per-host divergence. `compress=zstd:1` on root/nix/home/
snapshots; not on swap. The `/swap` subvol is nodatacow so NixOS's
`mkswap-swap-swapfile.service` can create the swapfile on first
boot without a separate `chattr +C` step. `/.snapshots` is
provisioned but not yet wired into snapper.

**vm** (ah-1 and any other Proxmox VM):

```
p1: 1 GiB   vfat ESP                 partlabel=disk-main-ESP        → /boot
p2: rest    ext4                     partlabel=disk-main-nixos      → /
```

UEFI-only (OVMF). No swap, no subvols. ext4 instead of btrfs because
the storage stack is Proxmox-over-NFS-over-TrueNAS-ZFS — ZFS already
provides CoW, checksums, snapshots, integrity at the bottom layer,
so a guest btrfs would be 3× CoW (btrfs in guest + qcow2 +
filesystem on ZFS) for no gain. ext4's lighter journal also wastes
fewer NFS round-trips.

## Adding a new host

See `AGENTS.md` § "Adding a new host" and § "Installing on real
hardware" for the canonical bring-up steps. Quick summary:

1. Write `flake-modules/hosts/<name>.nix`. Import
   `config.flake.modules.nixos.disko` and call
   `config.flake.lib.diskoLayouts.bare-metal` or `.vm` with the
   target disk path.
2. Run `sudo nixos-generate-config --no-filesystems
   --show-hardware-config > hosts/<name>/hardware-configuration.nix`
   on the actual hardware (or paste the all-zeros placeholder for
   smoke-build, with the `NIXOS_ALLOW_PLACEHOLDER=1` assertion).
3. `git add` everything new.
4. Smoke build with `nix build .#nixosConfigurations.<name>.config.system.build.toplevel`.
5. Real install: boot a live USB, clone the flake, run
   `sudo ./scripts/host-setup.sh --install <name>`.

## Hibernate-resume first-boot wart

`battery.nix`'s `swapDevices` entry creates `/swap/swapfile` on first
boot via `mkswap-swap-swapfile.service`. The kernel cmdline ships
with `resume_offset=0`, so the very first hibernate-resume attempt
after a fresh install will silently fail and the kernel will boot
fresh. The `battery-resume-offset.service` unit logs the correct
offset on each boot when there's a mismatch; copy that value into
the host bridge's `boot.kernelParams` override, rebuild, reboot, and
hibernate-resume works from then on. One-time per host.

(The previous host-setup.sh had a swapfile-provisioning + bridge-
patch + nixos-install-rerun dance to avoid this; with disko, the
extra complexity wasn't worth saving one reboot per fresh install.)

## Retirement condition

Retire this runbook entirely when disko (or a successor) publishes
a turnkey "boot live ISO → declarative install in one command"
workflow that subsumes `host-setup.sh --install` upstream. Until
then, the layout templates and the live-USB install command are the
canonical bring-up path.
