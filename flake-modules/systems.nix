# Systems for which per-system flake outputs (devShells, formatter,
# packages, apps, checks) are produced.
#
# This is the only place to add a new build target architecture. Hosts
# pick their `nixpkgs.hostPlatform` independently in their own host
# module under ./hosts/.
#
# Retire when: never, while flake-parts drives perSystem outputs. The
#   set of architectures may change (drop aarch64-linux, add darwin),
#   but a `systems` declaration is mandatory for as long as perSystem
#   exists.
{
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
}
