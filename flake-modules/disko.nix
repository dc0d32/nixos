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
#       Factory: `{ disk, swapSize ? null, luks ? false }: <module attrset>`
#       producing the shared layout used by every bare-metal host in
#       the repo (pb-x1, pb-t480, m-pc):
#         p1: 1 MiB bios-boot (ef02)
#         p2: 1 GiB vfat ESP                        → /boot
#         p3: <swapSize> swap (8200, present only when swapSize != null)
#                                                   partlabel=disk-main-swap
#         p4: rest  btrfs                           partlabel=disk-main-nixos
#               subvol=root                         → /
#               subvol=nix                          → /nix
#               subvol=home                         → /home
#               subvol=snapshots                    → /.snapshots
#       Hybrid bios-boot + ESP lets one layout boot on BIOS firmware
#       (m-pc, Compaq SFF, via grub) and UEFI firmware (laptops, via
#       systemd-boot) without per-host divergence.
#
#       Swap lives on its own GPT partition (type 8200) when
#       `swapSize` is non-null. The disko swap content type sets
#       `boot.resumeDevice` to /dev/disk/by-partlabel/disk-main-swap
#       automatically, so hibernate-resume just works — no
#       `resume_offset=` dance, no `btrfs inspect-internal map-swapfile`
#       service, no per-host kernelParam pin. Trade-off: swap size is
#       fixed at install time (resize means partition reshape +
#       mkswap, see scripts/disko-migrate.sh / docs/sessions/…). For
#       hibernate, size should be >= installed RAM. Set
#       `swapSize = null` (the default) for hosts that don't need
#       swap (e.g. servers with enough RAM, hosts that never
#       hibernate).
#
#       The `snapshots` subvol is materialized now as a slot for
#       future snapper/btrfs-snapshot wiring; it's empty until that
#       lands. Subvol names are bare (no `@` prefix) to match the
#       convention already in the running pb-x1 / pb-t480 installs.
#
#       With luks=true, p4 is LUKS2-encrypted and btrfs goes on top
#       of /dev/mapper/cryptroot. The disko script prompts for the
#       passphrase interactively at install time (no passphrase or
#       keyfile is ever materialized in the nix store). At boot, the
#       generated `boot.initrd.luks.devices.cryptroot` entry prompts
#       the same way. The swap partition is NOT wrapped in LUKS;
#       hibernate writes plaintext memory image to swap, which is a
#       conscious trade-off — if you need encrypted hibernate, change
#       this factory to wrap the swap partition in LUKS too (or move
#       swap inside the encrypted btrfs, accepting the
#       swapfile-resume-offset complexity that comes with it).
#   * flake.lib.diskoLayouts.vm
#       Factory: `{ disk, swapSize ? null, luks ? false }: <module attrset>`
#       for VM hosts (ah-1):
#         p1: 1 GiB vfat ESP                        → /boot
#         p2: <swapSize> swap (present only when swapSize != null)
#                                                   partlabel=disk-main-swap
#         p3: rest  ext4                            → /
#       UEFI only (OVMF). ext4 — Proxmox storage is NFS-mounted from
#       TrueNAS ZFS; ZFS provides CoW, checksums, snapshots, and
#       integrity at the bottom of the stack. Guest btrfs would be
#       three layers of CoW (btrfs + qcow2 + ZFS) and waste NFS round
#       trips on metadata-CoW operations the lower stack already
#       handles end-to-end. Guest ext4 is the right thin linear-write
#       layer for this substrate.
#
#       luks=true is supported here too but rarely useful: the
#       hypervisor (or the underlying ZFS pool) usually owns
#       encryption for guest images. Available so that "encrypt
#       everything" remains a one-flag toggle in egghead even for
#       VM-class hosts.
#
# Why factories rather than fixed modules:
#   The `disk` device path + `swapSize` are the only per-host knobs
#   (everything else is uniform across the host class), so each host
#   bridge writes:
#
#     (config.flake.lib.diskoLayouts.bare-metal {
#       disk = "/dev/nvme0n1";
#       swapSize = "32G";
#     })
#
#   Adding a new bare-metal host is a few-line call site. The factory
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
{ inputs, lib, ... }:
let
  # Impure side channel for the install-time LUKS passphrase. When
  # egghead is enrolling a TPM2 keyslot it needs disko to format +
  # open the LUKS container non-interactively (so the passphrase can
  # be fed to `systemd-cryptenroll --unlock-key-file=…` right after).
  # The wizard writes the passphrase to a tmpfs file, exports its
  # path here, and shreds it post-install.
  #
  # Reads:
  #   EGGHEAD_LUKS_PASSWORD_FILE  absolute path to a 0600 tmpfs file
  #                               containing the raw passphrase.
  #   When unset/empty (the default), disko falls back to its TTY
  #   askpass — same UX hosts have always had. Requires the disko
  #   build to be `--impure`, which scripts/host-setup.sh already is.
  luksPasswordFile =
    let f = builtins.getEnv "EGGHEAD_LUKS_PASSWORD_FILE";
    in if f == "" then null else f;

  withPasswordFile = luksContent:
    if luksPasswordFile == null
    then luksContent
    else luksContent // { passwordFile = luksPasswordFile; };
in
{
  flake.modules.nixos.disko = {
    imports = [ inputs.disko.nixosModules.disko ];
  };

  flake.lib.diskoLayouts = {
    # Bare-metal: bios-boot + ESP + optional swap + btrfs with subvols.
    # Optional LUKS wrap around the btrfs partition only (NOT swap —
    # see the header for the trade-off).
    bare-metal = { disk, swapSize ? null, luks ? false }:
      let
        # The btrfs content block is the same regardless of whether
        # it lives directly on the partition or inside a LUKS mapper.
        # No `swap` subvol any more — swap is its own partition
        # (when swapSize != null) rather than a swapfile in a no-CoW
        # subvol. That's what eliminates the resume_offset song and
        # dance the older layout required.
        btrfsContent = {
          type = "btrfs";
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
            # Empty slot for future snapper / btrfs-snapshot wiring
            # (snapper conventionally places snapshots under
            # /.snapshots). Not referenced by anything today; remove
            # this subvol from the factory if you decide snapshots
            # aren't worth the metadata footprint.
            "snapshots" = {
              mountpoint = "/.snapshots";
              mountOptions = [ "compress=zstd:1" "noatime" ];
            };
          };
        };
        nixosPartContent =
          if luks then
            withPasswordFile
              {
                type = "luks";
                name = "cryptroot";
                settings = {
                  allowDiscards = true;
                  bypassWorkqueues = true;
                };
                content = btrfsContent;
              }
          else
            btrfsContent;

        # priority=1 puts BIOS-boot first, then ESP, then (optional)
        # swap, then nixos catching the rest. Explicit priorities
        # because nix attrset order is alphabetical, which would
        # otherwise interleave wrong (e.g. ESP < BIOS < nixos < swap).
        # Disko sorts partitions within a gpt content by `priority`
        # ascending; the 100% size on nixos still slots it last
        # regardless, but the explicit ordering keeps disko's parted
        # invocations deterministic.
        swapPartition = lib.optionalAttrs (swapSize != null) {
          swap = {
            size = swapSize;
            # 8200 = Linux swap GPT GUID. Sets the partition type so
            # systemd-gpt-auto-generator (if ever enabled) and other
            # auto-discovery tools recognise it as swap.
            type = "8200";
            priority = 3;
            content = {
              type = "swap";
              # Disko sets boot.resumeDevice to
              # /dev/disk/by-partlabel/disk-main-swap when this is
              # true. That's what makes hibernate-resume work without
              # any per-host kernelParam.
              resumeDevice = true;
              # No randomEncryption: a random key per-boot would break
              # hibernate-resume (the kernel can't decrypt the suspend
              # image with a new key). If you don't want plaintext
              # swap, switch luks=true on the whole disk — but see the
              # factory header for why swap isn't LUKS-wrapped here.
            };
          };
        };
      in
      {
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
                priority = 2;
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "fmask=0022" "dmask=0022" ];
                };
              };
              nixos = {
                size = "100%";
                priority = 4;
                content = nixosPartContent;
              };
            } // swapPartition;
          };
        };
      };

    # VM: ESP + optional swap + ext4 (no bios-boot, no subvols).
    # Optional LUKS wrap; usually unnecessary because the hypervisor /
    # ZFS pool already encrypts the backing store.
    vm = { disk, swapSize ? null, luks ? false }:
      let
        ext4Content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
          extraArgs = [ "-L" "nixos" ];
        };
        nixosPartContent =
          if luks then
            withPasswordFile
              {
                type = "luks";
                name = "cryptroot";
                settings = {
                  allowDiscards = true;
                  bypassWorkqueues = true;
                };
                content = ext4Content;
              }
          else
            ext4Content;
        swapPartition = lib.optionalAttrs (swapSize != null) {
          swap = {
            size = swapSize;
            type = "8200";
            priority = 2;
            content = {
              type = "swap";
              resumeDevice = true;
            };
          };
        };
      in
      {
        disko.devices.disk.main = {
          type = "disk";
          device = disk;
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "1G";
                type = "EF00";
                priority = 1;
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "fmask=0022" "dmask=0022" ];
                };
              };
              nixos = {
                size = "100%";
                priority = 3;
                content = nixosPartContent;
              };
            } // swapPartition;
          };
        };
      };
  };
}
