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
#               subvol=persist                      → /persist
#               subvol=snapshots                    → /.snapshots
#               (RO snapshot of empty root)         → root-blank
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
#       mkswap, see docs/sessions/…). For
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
#       The `persist` subvol + the `root-blank` RO snapshot are
#       wired for flake-modules/impermanence.nix. Both are created
#       unconditionally because the cost is negligible (one
#       mountpoint, one empty-subvol snapshot) and having them ready
#       means a host can opt into impermanence by importing the
#       module + rebooting — no disk-level migration needed. On
#       hosts that don't import impermanence today, /persist is just
#       an empty subvol with no bind-mounts pointing into it, and
#       root-blank sits unused at the btrfs top level.
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
#       for VM hosts:
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
#       everything" remains a one-flag toggle even for VM-class
#       hosts.
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
#   on a VM guest (virtio) — there is no shared default. Forcing the call
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
          # postCreateHook runs after `mkfs.btrfs` + all the
          # `btrfs subvolume create` calls; we use it to materialize
          # an empty RO snapshot of the freshly-created `root` subvol
          # named `root-blank`. The impermanence module's initrd
          # rollback service restores `root` from this snapshot on
          # every boot (flake-modules/impermanence.nix).
          #
          # The snapshot is tiny (it captures an empty subvol — a
          # handful of inodes the kernel materializes for any
          # subvolume) and harmless on hosts that don't import the
          # impermanence module; it just sits unused at the btrfs
          # top level. Doing it here means every host that uses this
          # factory is "impermanence-ready" without per-host wiring.
          #
          # Implementation detail: disko exports a `device` shell
          # variable into the hook scope (via defineHookVariables —
          # this is the btrfs type's `config.device`, which is
          # `/dev/disk/by-partlabel/disk-main-nixos` on plain hosts
          # and `/dev/mapper/cryptroot` on LUKS hosts since the LUKS
          # wrapper sets its content's `device` to the mapper path).
          # We mount subvolid=5 (the btrfs top level) at a temp dir,
          # snapshot root → root-blank, then unmount.
          postCreateHook = ''
            MNTPOINT=$(mktemp -d)
            mount -t btrfs "$device" "$MNTPOINT" -o subvol=/
            trap 'umount "$MNTPOINT"; rm -rf "$MNTPOINT"' EXIT
            if ! btrfs subvolume show "$MNTPOINT/root-blank" >/dev/null 2>&1; then
              btrfs subvolume snapshot -r "$MNTPOINT/root" "$MNTPOINT/root-blank"
            fi
          '';
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
            # Persistence subvol for the impermanence module
            # (flake-modules/impermanence.nix). Created unconditionally
            # because the cost is one inode + a mountpoint, and having
            # it ready means a host can opt into impermanence by
            # importing the module + reboot — no disk-level migration
            # needed. On hosts that DON'T import impermanence, the
            # /persist mountpoint exists and is writable but no
            # bind-mounts point into it; harmless.
            "persist" = {
              mountpoint = "/persist";
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

    # Bare-metal ZFS-on-root: hybrid bios-boot + ESP + optional swap + a
    # single-disk `rpool` with datasets root(/) nix(/nix) home(/home)
    # persist(/persist) and a `root@blank` snapshot. Used by the homelab
    # nodes (ursa, andromeda) so both boxes are ZFS end to end (this boot
    # pool + andromeda's zrust data pool), and both can run impermanence.
    #
    # The `root@blank` snapshot is the ZFS analogue of the btrfs
    # `root-blank` subvol: flake-modules/impermanence.nix with
    # `backend = "zfs"` rolls the root dataset back to it in initrd on
    # every boot. /nix + /home + /persist are separate datasets and are
    # never rolled back, so they survive.
    #
    # rootFsOptions match the OpenZFS-on-root conventions (posixacl + sa
    # xattrs so systemd/journald ACLs work, zstd compression, atime off,
    # mountpoint=none so children mount by their explicit `mountpoint`).
    # ashift=12 (4K) is right for every SSD/HDD we run.
    #
    # UEFI + BIOS both boot: /boot is a plain vfat ESP (kernel+initrd), so
    # systemd-boot (UEFI) loads them and the initrd imports rpool; the 1 MiB
    # bios-boot partition lets grub boot the same disk on legacy firmware
    # (the R720 may be BIOS). LUKS is intentionally NOT offered here — for
    # ZFS the idiomatic encryption is native ZFS encryption, added later if
    # wanted; the homelab chose no encryption for now.
    #
    # NOTE: a host using this MUST set `networking.hostId` (ZFS refuses to
    # import without one) — the homelab bridges already do.
    zfs-bare-metal = { disk, poolName ? "rpool", swapSize ? null }:
      let
        swapPartition = lib.optionalAttrs (swapSize != null) {
          swap = {
            size = swapSize;
            type = "8200";
            priority = 3;
            content = {
              type = "swap";
              resumeDevice = true;
            };
          };
        };
      in
      {
        disko.devices = {
          disk.main = {
            type = "disk";
            device = disk;
            content = {
              type = "gpt";
              partitions = {
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
                zfs = {
                  size = "100%";
                  priority = 4;
                  content = {
                    type = "zfs";
                    pool = poolName;
                  };
                };
              } // swapPartition;
            };
          };
          zpool.${poolName} = {
            type = "zpool";
            options.ashift = "12";
            rootFsOptions = {
              compression = "zstd";
              acltype = "posixacl";
              xattr = "sa";
              atime = "off";
              mountpoint = "none";
              "com.sun:auto-snapshot" = "false";
            };
            datasets = {
              # Ephemeral root — rolled back to @blank every boot by the
              # impermanence module. The postCreateHook takes the empty
              # snapshot at install time.
              root = {
                type = "zfs_fs";
                mountpoint = "/";
                postCreateHook = "zfs snapshot ${poolName}/root@blank";
              };
              nix = {
                type = "zfs_fs";
                mountpoint = "/nix";
              };
              home = {
                type = "zfs_fs";
                mountpoint = "/home";
              };
              # Persistence dataset for impermanence (holds /persist/stacks,
              # /persist/secrets, and the bind-mount sources). Survives the
              # root rollback. neededForBoot (below) so it's mounted before
              # the impermanence bind mounts are set up.
              persist = {
                type = "zfs_fs";
                mountpoint = "/persist";
              };
            };
          };
        };
        # ZFS-in-initrd + early mounts. `/` (rpool/root) mounts via zfsutil;
        # the legacy-mountpoint datasets need explicit fileSystems entries
        # with neededForBoot so /nix + /persist are up before switch-root
        # and the impermanence bind mounts.
        #
        # These unattended homelab servers prioritize recovering automatically
        # after an unclean shutdown. This deliberately accepts the force-import
        # risk rather than requiring an operator to boot once with zfs_force=1.
        boot.zfs.forceImportRoot = lib.mkDefault true;
        fileSystems."/nix".neededForBoot = true;
        fileSystems."/persist".neededForBoot = true;
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
