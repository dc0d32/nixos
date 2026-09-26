# nvidia-server.nix — optional headless NVIDIA driver + container toolkit
# for homelab hosts with a native NVIDIA GPU.
#
# Why this exists:
#   Some homelab workloads use NVIDIA acceleration directly on the host
#   (without VFIO passthrough). This wires the proprietary driver + NVIDIA
#   container toolkit (CDI); only hosts with that hardware should import it
#   and enable `homelab.nvidia`.
#
# Note: enabling requires unfree (`nixpkgs.config.allowUnfree = true`) on
# the host — the driver is unfree. Set that in the GPU host bridge.
#
# Inert until `homelab.nvidia.enable = true`.
#
# Retire when: no host needs native NVIDIA drivers or container CDI.
{ ... }:
{
  flake.modules.nixos.nvidia-server = { config, lib, ... }:
    let
      cfg = config.homelab.nvidia;
    in
    {
      options.homelab.nvidia.enable =
        lib.mkEnableOption "headless NVIDIA driver + container toolkit";

      config = lib.mkIf cfg.enable {
        hardware.graphics.enable = true;
        # Selects the nvidia kmod even without an X server.
        services.xserver.videoDrivers = [ "nvidia" ];
        hardware.nvidia = {
          # 2080 Ti (Turing) → proprietary kmod (open kmod is Ampere+).
          open = lib.mkDefault false;
          modesetting.enable = true;
          nvidiaSettings = false;
          package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.production;
        };
        # CDI for docker/podman GPU access.
        hardware.nvidia-container-toolkit.enable = true;
      };
    };
}
