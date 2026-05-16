# disko — declarative disk partitioning + formatting.
#
# Publishes:
#   * flake.modules.nixos.disko
#       Importing this in a host bridge wires
#       `inputs.disko.nixosModules.disko` into that NixOS config. The
#       disko module reads `disko.devices` from the same config and
#       synthesizes `config.fileSystems.*`, `swapDevices`, and (when
#       LUKS is used) `boot.initrd.luks.devices.*` automatically. Hosts
#       no longer need to maintain `fileSystems.*` blocks in
#       `hardware-configuration.nix` by hand.
#   * flake.lib.diskoLayouts.bare-metal
#       Factory: `{ disk }: <module attrset>` producing the shared
#       layout used by every bare-metal host in the repo (pb-x1,
#       pb-t480, m-pc):
#         p1: 1 MiB bios-boot (ef02)
#         p2: 1 GiB vfat ESP                       → /boot
#         p3: rest  btrfs                          partlabel=nixos
#               subvol=root                        → /
#               subvol=nix                         → /nix
#               subvol=home                        → /home
#               subvol=swap          (nodatacow)   → /swap
#               subvol=snapshots     (nodatacow)   → /.snapshots
#       Hybrid bios-boot + ESP lets one layout boot on BIOS firmware
#       (m-pc, Compaq SFF, via grub) and UEFI firmware (laptops, via
#       systemd-boot) without per-host divergence. The `swap` subvol
#       has CoW disabled via `nodatacow` mount option so battery.nix's
#       `/swap/swapfile` lives on a CoW-free subvol without the
#       chattr +C dance the previous install pattern required (the
#       kernel refuses to use swap files on CoW-enabled btrfs subvols).
#       The `snapshots` subvol is materialized now as a slot for future
#       snapper/btrfs-snapshot wiring; it's empty until that lands.
#       Subvol names are bare (no `@` prefix) to match the convention
#       already in the running pb-x1 / pb-t480 installs.
#   * flake.lib.diskoLayouts.vm
#       Factory: `{ disk }: <module attrset>` for VM hosts (ah-1):
#         p1: 1 GiB vfat ESP                       → /boot
#         p2: rest  ext4                           → /
#       UEFI only (OVMF). ext4 — Proxmox storage is NFS-mounted from
#       TrueNAS ZFS; ZFS provides CoW, checksums, snapshots, and
#       integrity at the bottom of the stack. Guest btrfs would be
#       three layers of CoW (btrfs + qcow2 + ZFS) and waste NFS round
#       trips on metadata-CoW operations the lower stack already
#       handles end-to-end. Guest ext4 is the right thin linear-write
#       layer for this substrate.
#
# Why factories rather than fixed modules:
#   The `disk` device path is the only per-host knob (everything else
#   is uniform across the host class), so each host bridge writes:
#
#     # hosts/<name>/disko.nix
#     { config, ... }:
#     config.flake.lib.diskoLayouts.bare-metal { disk = "/dev/nvme0n1"; }
#
#   Adding a new bare-metal host is a one-line call site. The factory
#   pattern mirrors `flake.lib.mkPkgs` (mk-pkgs.nix) and
#   `flake.lib.bundles.homeManager.*` (bundles/).
#
# Why not encode the disk path inside the factory:
#   /dev/nvme0n1 on the laptops, /dev/sda on m-pc (SATA SSD), /dev/vda
#   on ah-1 (virtio) — there is no shared default. Forcing the call
#   site to name it keeps "which disk this host installs to" visible in
#   the per-host file rather than buried in a shared module.
#
# Why partlabels (BIOS / ESP / nixos) rather than by-uuid:
#   disko-install generates fresh UUIDs every run; partlabels are
#   stable across reinstalls of the same layout. The generated
#   `fileSystems.*` entries use `/dev/disk/by-partlabel/<label>` so
#   replacing a disk and re-running disko-install produces an
#   identical-by-name root device.
#
# Retire when:
#   * The repo moves to ZFS-on-root or some other layout disko doesn't
#     model cleanly, OR
#   * NixOS gains a first-class declarative partitioning system that
#     supersedes disko (no concrete proposal as of this writing).
{ inputs, ... }:
{
  flake.modules.nixos.disko = {
    imports = [ inputs.disko.nixosModules.disko ];
  };

  flake.lib.diskoLayouts = {
    # Bare-metal: bios-boot + ESP + btrfs with subvols.
    bare-metal = { disk }: {
      disko.devices.disk.main = {
        type = "disk";
        device = disk;
        content = {
          type = "gpt";
          partitions = {
            # 1 MiB BIOS-boot partition. Required for grub on BIOS
            # firmware; ignored by systemd-boot on UEFI. Costs nothing
            # and lets every bare-metal host share one layout module
            # regardless of firmware mode.
            BIOS = {
              size = "1M";
              type = "EF02";
              priority = 1;
            };
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "fmask=0022" "dmask=0022" ];
              };
            };
            nixos = {
              size = "100%";
              content = {
                type = "btrfs";
                # `-f` forces overwrite of any existing signature on
                # the partition — disko's --mode disko/destroy is
                # already destructive, this just suppresses the
                # interactive confirmation. `-L nixos` sets a
                # filesystem label matching the partition label so
                # `btrfs filesystem show` reads naturally.
                extraArgs = [ "-L" "nixos" "-f" ];
                subvolumes = {
                  "root" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd:1" "noatime" ];
                  };
                  "nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "compress=zstd:1" "noatime" ];
                  };
                  "home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd:1" "noatime" ];
                  };
                  # CoW disabled on this subvol via `nodatacow` mount
                  # option. battery.nix's swapDevices entry creates
                  # /swap/swapfile here; the kernel requires
                  # swapfiles on btrfs to be on a CoW-disabled,
                  # non-snapshotted subvol with a single contiguous
                  # extent. Mounting nodatacow at format-time means
                  # any file created here inherits the
                  # no-data-checksum + no-CoW attributes without an
                  # explicit `chattr +C` step.
                  "swap" = {
                    mountpoint = "/swap";
                    mountOptions = [ "nodatacow" "noatime" ];
                  };
                  # Empty slot for future snapper / btrfs-snapshot
                  # wiring (snapper conventionally places snapshots
                  # under /.snapshots). Not referenced by anything
                  # today; remove this subvol from the factory if you
                  # decide snapshots aren't worth the metadata
                  # footprint.
                  "snapshots" = {
                    mountpoint = "/.snapshots";
                    mountOptions = [ "compress=zstd:1" "noatime" ];
                  };
                };
              };
            };
          };
        };
      };
    };

    # VM: ESP + ext4 (no swap, no bios-boot, no subvols).
    vm = { disk }: {
      disko.devices.disk.main = {
        type = "disk";
        device = disk;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "fmask=0022" "dmask=0022" ];
              };
            };
            nixos = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                extraArgs = [ "-L" "nixos" ];
              };
            };
          };
        };
      };
    };
  };
}
