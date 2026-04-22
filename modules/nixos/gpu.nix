{ config, lib, pkgs, variables, ... }:
# Graphics driver selection.
#
# Set `variables.gpu.driver` in hosts/<h>/variables.nix to one of:
#   "intel"  — modern Intel iGPU (Tiger Lake and newer use intel-media-driver;
#              older can fall back to i965 — uncomment below if needed)
#   "amd"    — AMD GPU via amdgpu + RADV (Mesa)
#   "nvidia" — NVIDIA proprietary driver (stable branch by default)
#   "none"   — skip GPU-specific setup (VMs, headless)
let
  driver = variables.gpu.driver or "none";
in
{
  # Modern name in nixpkgs; also export hardware.graphics for compatibility.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # ---------- Intel ----------
  hardware.graphics.extraPackages = lib.mkIf (driver == "intel") (with pkgs; [
    intel-media-driver           # VAAPI driver for modern Intel (Broadwell+)
    vaapiIntel                   # legacy fallback (older iGPUs)
    vaapiVdpau
    libvdpau-va-gl
  ]);

  # ---------- AMD ----------
  # xorg kept optional; niri is Wayland so xserver is not strictly required.
  services.xserver.videoDrivers =
    if driver == "amd"    then [ "amdgpu" ]
    else if driver == "nvidia" then [ "nvidia" ]
    else if driver == "intel"  then [ "modesetting" ]
    else [ ];

  # ---------- NVIDIA ----------
  hardware.nvidia = lib.mkIf (driver == "nvidia") {
    modesetting.enable = true;
    powerManagement.enable = true;
    open = false;                 # set true if you want the open kernel module
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  boot.kernelParams = lib.mkMerge [
    (lib.mkIf (driver == "nvidia") [ "nvidia-drm.modeset=1" ])
  ];

  # Vulkan + 32-bit userspace for gaming / wine. RADV is the default Vulkan
  # driver on Mesa and requires no extra packages beyond `mesa`, which nix
  # pulls in via hardware.graphics.enable.

  # Sanity warnings
  warnings = lib.optionals (!(builtins.elem driver [ "intel" "amd" "nvidia" "none" ])) [
    "variables.gpu.driver = \"${driver}\" is not one of intel|amd|nvidia|none"
  ];
}
