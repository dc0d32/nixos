{
  # Host identity
  hostname = "CHANGEME";
  user = "CHANGEME";

  # Architecture & release
  system = "x86_64-linux";
  stateVersion = "24.11";

  # Locale / time
  timezone = "America/Los_Angeles";
  locale = "en_US.UTF-8";
  keymap = "us";

  # Feature flags consumed by modules/nixos/* and modules/home/*
  desktop = {
    niri.enable = true;
    # Pick ONE status bar / shell. Enabling both will draw two panels.
    waybar.enable = true;
    quickshell.enable = false;
  };

  audio.pipewire.enable = true;

  gpu = {
    # one of: "intel" | "amd" | "nvidia" | "none"
    driver = "intel";
  };

  # Optional: per-host monitor layout used by niri home module
  # monitors = [
  #   { name = "DP-1"; mode = "2560x1440@144"; position = "0,0"; scale = 1.0; }
  # ];
}
