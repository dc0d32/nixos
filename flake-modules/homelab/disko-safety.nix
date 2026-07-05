# disko-safety.nix — refuse to build if a disko target is an unstable
# device path.
#
# Why this exists:
#   disko wipes/formats ONLY the disks named in `disko.devices.disk.*.device`
#   — it never touches a disk it isn't told about. The real hazard on a
#   multi-disk server is therefore not disko "reaching" extra disks, but the
#   named `device` VALUE resolving to the WRONG physical disk. On hosts with
#   many disks (andromeda: 2 boot SSDs + 8 `zrust` raidz2 members), the
#   kernel's `/dev/sdX` enumeration is NOT stable across boots / kernels /
#   HBA init order, so a bare `/dev/sda` could point at a pool member on any
#   given boot. `install.sh`'s destructive pre-wipe reads the same value, so
#   a wrong `device` is doubly dangerous.
#
#   Importing this module makes such a mistake un-buildable: every
#   `disko.devices.disk.*.device` on the host MUST be a stable
#   `/dev/disk/by-id/…` path (serial / WWN), which always resolves to one
#   specific physical drive regardless of enumeration order.
#
#   Import it on any multi-disk host (the homelab nodes) alongside
#   `flake.modules.nixos.disko`. Single-disk hosts (laptops) don't need it
#   and are unaffected — this only publishes a module; it does nothing until
#   a host imports it.
#
# Retire when:
#   * disko upstream grows an equivalent "require stable identifier" guard, OR
#   * the repo stops using disko (see flake-modules/disko.nix retirement note).
{ ... }:
{
  flake.modules.nixos.disko-safety = { config, lib, ... }:
    let
      disks = config.disko.devices.disk or { };
      isStable = dev: lib.hasPrefix "/dev/disk/by-id/" dev;
      bad = lib.filterAttrs (_: d: !isStable (d.device or "")) disks;
      badList = lib.mapAttrsToList (n: d: "${n} → ${toString (d.device or "<unset>")}") bad;
    in
    {
      assertions = [
        {
          assertion = bad == { };
          message = ''
            disko-safety: the following disko disks target UNSTABLE device
            paths. On a multi-disk host this risks wiping the wrong drive:

              ${lib.concatStringsSep "\n  " badList}

            Pin each to a stable /dev/disk/by-id/ path (serial or WWN), e.g.
              /dev/disk/by-id/ata-SAMSUNG_MZ7WD480HCGM-000H2_S1T9NYAG200249
            /dev/sdX, /dev/nvmeXnY and /dev/vdX are rejected here because
            their enumeration is not stable across boots.
          '';
        }
      ];
    };
}
