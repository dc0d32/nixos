# nvidia-server.nix — headless NVIDIA driver + container toolkit for the
# GPU homelab node.
#
# Why this exists:
#   The heavy stack (immich-ML, frigate, ollama, plex) uses the 2080 Ti
#   NATIVELY on bare metal (no VFIO passthrough). This wires the
#   proprietary driver + the NVIDIA container toolkit (CDI) so docker
#   `--gpus`/`deploy.resources` works. Gated so only the GPU node enables
#   it.
#
# Note: enabling requires unfree (`nixpkgs.config.allowUnfree = true`) on
# the host — the driver is unfree. Set that in the GPU host bridge.
#
# Inert until `homelab.nvidia.enable = true`.
#
# Retire when: the homelab GPU moves to a VM (VFIO) again, or to a
#   different vendor.
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
