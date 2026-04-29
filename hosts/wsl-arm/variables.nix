{
  # Host identity
  hostname = "wsl-arm";
  user = "p";

  # Architecture & release
  system = "aarch64-linux";
  stateVersion = "25.11";

  # Locale / time
  timezone = "America/Los_Angeles";
  locale = "en_US.UTF-8";
  keymap = "us";

  # --- Feature flags consumed by modules/nixos/* and modules/home/* ---

  desktop = {
    niri.enable = false;
    # Pick ONE status bar / shell. Enabling both will draw two panels.
    waybar.enable = false;
    quickshell.enable = false;
    wallpaper = {
      enable = false;
      intervalMinutes = 30;
    };
  };

  audio.pipewire.enable = false;

  audio.easyeffects = {
    enable = false;
  };

  # Graphics driver. One of: "intel" | "amd" | "nvidia" | "none"
  # Consumed by modules/nixos/gpu.nix.
  gpu = {
    driver = "none";
  };

  # Login manager (ly — tiny TUI DM)
  login.ly.enable = false;

  # Auto-lock / DPMS / suspend timings (seconds). Applied by
  # modules/home/desktop/idle.nix via stasis under the user's session.
  idle = {
    enable = false;
    lockAfter    = 300;   # 5 min
    dpmsAfter    = 420;   # 7 min
    suspendAfter = 900;   # 15 min
  };

  # WSL (Windows Subsystem for Linux). Flip on for a WSL distro, including
  # Windows-on-ARM (aarch64-linux). When enabled, modules/nixos/wsl.nix
  # imports the wsl.nix file from github:dc0d32/nixos-aarch64-wsl and
  # disables bootloader/DM/niri/pipewire/gpu/power.
  wsl = {
    # (set by new-host --wsl)
    enable = true;
    # defaultUser = variables.user;   # falls back to variables.user automatically
  };

  apps = {
    chrome.enable = false;   # linux only; no-op on mac
    vscode.enable = false;
    bitwarden.enable = false;
  };

  biometrics.enable = false;

  sshAgent.enable = false;

  hardwareHacking.enable = false;

  # Optional git identity merged into modules/home/git.nix
  git = {
    name  = "CHANGEME";
    email = "CHANGEME@example.com";
  };
}
