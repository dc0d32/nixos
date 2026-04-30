# Systems for which per-system flake outputs (devShells, formatter,
# packages, apps, checks) are produced.
#
# This is the only place to add a new build target architecture. Hosts
# pick their `nixpkgs.hostPlatform` independently in their own host
# module under ./hosts/.
{
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
}
