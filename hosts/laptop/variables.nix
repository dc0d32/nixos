{
  # Host identity
  hostname = "laptop";
  user = "p";

  # Architecture & release
  system = "x86_64-linux";
  stateVersion = "25.11";

  # Locale / time
  timezone = "America/Los_Angeles";
  locale = "en_US.UTF-8";
  keymap = "us";

  # --- Feature flags consumed by modules/nixos/* and modules/home/* ---

  desktop = {
    niri.enable = true;
    # Pick ONE status bar / shell. Enabling both will draw two panels.
    waybar.enable = false;
    quickshell.enable = true;
    wallpaper = {
      enable = true;
      intervalMinutes = 30;
    };
  };

  audio.pipewire.enable = true;

  audio.easyeffects = {
    enable = true;
    preset = "X1Yoga7-Dynamic-Detailed";
    presetsDir = ./audio-presets;
    irsDir = ./audio-irs;
    # Autoload: apply preset automatically when this output device appears.
    # Get the device name with: wpctl inspect @DEFAULT_AUDIO_SINK@ | grep node.name
    autoloadDevice = "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink";
    autoloadDeviceProfile = "Speaker";
    autoloadDeviceDescription = "Alder Lake PCH-P High Definition Audio Controller Speaker";
  };

  # Graphics driver. One of: "intel" | "amd" | "nvidia" | "none"
  # Consumed by modules/nixos/gpu.nix.
  gpu = {
    driver = "intel";
  };

  # Login manager (ly — tiny TUI DM)
  login.ly.enable = true;

  # Auto-lock / DPMS / suspend timings (seconds). Applied by
  # modules/home/desktop/idle.nix via stasis under the user's session.
  idle = {
    enable = true;
    lockAfter = 300;
    dpmsAfter = 420;
    suspendAfter = 900;
  };

  # WSL (Windows Subsystem for Linux). Flip on for a WSL distro, including
  # Windows-on-ARM (aarch64-linux). When enabled, modules/nixos/wsl.nix
  # imports the wsl.nix file from github:dc0d32/nixos-aarch64-wsl and
  # disables bootloader/DM/niri/pipewire/gpu/power.
  wsl = {
    enable = false;
    # defaultUser = variables.user;   # falls back to variables.user automatically
  };

  apps = {
    chrome.enable = true;
    vscode.enable = true;
    bitwarden.enable = true;
  };

  biometrics.enable = true;

  hardwareHacking.enable = true;

  sshAgent.enable = false;

  # Optional git identity merged into modules/home/git.nix
  git = {
    name = "CHANGEME";
    email = "CHANGEME@example.com";
  };
}
