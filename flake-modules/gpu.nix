# Graphics driver selection.
#
# Hosts that import this feature must set `gpu.driver` to one of:
#   "intel"  — modern Intel iGPU (Tiger Lake and newer use intel-media-driver;
#              older can fall back to i965 — uncomment below if needed)
#   "amd"    — AMD GPU via amdgpu + RADV (Mesa)
#   "nvidia" — NVIDIA proprietary driver (stable branch by default)
#   "none"   — skip GPU-specific setup (VMs, headless)
#
# Pattern A: hosts opt in by importing this module. WSL / headless
# hosts simply don't import it. The "none" value exists for hosts
# that import the module but want a no-op driver setup (e.g. for the
# hardware.graphics defaults without picking a vendor).
#
# Per-NixOS-config option scoping: `options.gpu.driver` is declared
# INSIDE the NixOS module body (not at the flake-parts top level) so
# each NixOS configuration can pick its own driver. Declaring it at
# the flake-parts level would make it a global singleton and any two
# hosts with different GPUs (e.g. pb-x1 intel + m-pc amd) would
# conflict. Hosts set `gpu.driver = "...";` inside their
# `configurations.nixos.<name>.module` block. Same scoping pattern as
# `battery.*` and HM-side `audio.*`/`idle.*` — see the long comments
# in those modules and the matching NOTE blocks in flake-modules/
# hosts/pb-x1.nix.
#
# Retire when: NixOS upstream auto-detects and configures the right
#   GPU stack (intel-media / amdgpu / nvidia) such that no per-host
#   `gpu.driver` selection is needed, OR every host in the repo
#   converges on a single driver and this dispatcher becomes overkill.
{
  flake.modules.nixos.gpu = { lib, pkgs, config, ... }:
    let
      driver = config.gpu.driver;
    in
    {
      options.gpu.driver = lib.mkOption {
        type = lib.types.enum [ "intel" "amd" "nvidia" "none" ];
        description = "GPU driver stack to enable on a host that imports the gpu module.";
      };

      config = {
        # Modern name in nixpkgs; also export hardware.graphics for
        # compatibility. mkDefault so WSL / headless hosts can disable
        # cleanly even when this module is imported.
        #
        # No enable32Bit: 32-bit GL libs were only needed for Steam,
        # which has been removed from this flake. If Steam returns,
        # nixpkgs' programs.steam sets hardware.graphics.enable32Bit =
        # true itself, so there's no need to carry it here.
        hardware.graphics = {
          enable = lib.mkDefault true;
        };

        # ---------- Intel ----------
        # Modern Intel iGPU (Broadwell+, 2014+) uses the iHD VAAPI
        # backend. For pre-Broadwell GPUs add `intel-vaapi-driver` (the
        # renamed i965-va-driver). For legacy apps that only speak
        # VDPAU, add `libvdpau-va-gl` as a bridge.
        hardware.graphics.extraPackages = lib.mkIf (driver == "intel") (with pkgs; [
          intel-media-driver
        ]);

        # Prefer the modern iHD VAAPI backend on Intel.
        environment.sessionVariables = lib.mkIf (driver == "intel") {
          LIBVA_DRIVER_NAME = "iHD";
        };

        # AMD/Intel/NVIDIA xorg drivers. mkDefault so WSL can clear the
        # list without mkForce and hosts can override directly.
        services.xserver.videoDrivers = lib.mkDefault (
          if driver == "amd" then [ "amdgpu" ]
          else if driver == "nvidia" then [ "nvidia" ]
          else if driver == "intel" then [ "modesetting" ]
          else [ ]
        );

        # ---------- NVIDIA ----------
        hardware.nvidia = lib.mkIf (driver == "nvidia") {
          modesetting.enable = true;
          powerManagement.enable = true;
          open = false; # set true if you want the open kernel module
          nvidiaSettings = true;
          package = config.boot.kernelPackages.nvidiaPackages.stable;
        };

        boot.kernelParams = lib.mkMerge [
          (lib.mkIf (driver == "nvidia") [ "nvidia-drm.modeset=1" ])
        ];

        # Vulkan + 32-bit userspace for gaming / wine. RADV is the
        # default Vulkan driver on Mesa and requires no extra packages
        # beyond `mesa`, which nix pulls in via hardware.graphics.enable.
      };
    };
}
