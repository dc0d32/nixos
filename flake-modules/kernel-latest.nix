# Latest mainline kernel for bare-metal graphical hosts.
#
# pb-x1 / m-pc / pb-t480 all want `linuxPackages_latest` (newer hardware
# support than the LTS default). Folded into the workstation bundle so
# each bridge doesn't repeat the line.
#
# mkDefault so a nixos-hardware module — or a host that needs to pin a
# specific kernel — can override without mkForce. On current kernels the
# `lenovo-*` modules' conditional `< 5.19` kernelPackages mkDefault never
# fires, so there is no competing definition to collide with.
#
# Retire when: the NixOS default kernel is recent enough for every
#   machine in the fleet, OR a host needs a pinned kernel (override
#   locally then).
{ ... }:
{
  flake.modules.nixos.kernel-latest = { lib, pkgs, ... }: {
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
  };
}
