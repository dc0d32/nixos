// Canonical list of NixOS-class feature modules that are sensible
// to toggle per-host. Order matters: it's the order they appear in
// the multi-select. Each entry: [key, oneLineDescription].
//
// Excluded by design (always-on substrate, auto-wired, or
// flow-controlled elsewhere):
//   - nix-settings networking openssh users system-utils locale
//     fonts boot home-manager-bootstrap   (substrate, always on)
//   - egghead-amend disko                 (always on for wizard hosts)
//   - auto-upgrade nixos-clone hm-auto-upgrade  (controlled by UNATTENDED)
//   - wsl                                 (different role flow entirely)
//
// Anything else in flake.modules.nixos.* that should be human-
// selectable goes here. Keep in sync with flake-modules/*.nix.
export interface FeatureSpec {
  key: string;
  description: string;
}

export const AVAILABLE_FEATURES: FeatureSpec[] = [
  // Graphical session stack
  { key: "niri", description: "scrollable-tiling Wayland compositor" },
  { key: "quickshell", description: "QML bar/lockscreen (pairs with niri)" },
  { key: "login-ly", description: "ly TUI display manager" },
  { key: "file-manager", description: "nautilus etc." },

  // Hardware
  { key: "gpu", description: "graphics driver wiring (Intel/AMD/Nvidia)" },
  { key: "audio", description: "PipeWire + EasyEffects per-sink presets" },
  { key: "bluetooth", description: "bluez stack + applets" },
  { key: "battery", description: "charge thresholds, hibernate-resume" },
  { key: "power", description: "power profiles, suspend tuning" },
  { key: "biometrics", description: "fingerprint reader / face unlock" },
  { key: "hardware-hacking", description: "openocd, st-link, jlink, etc." },
  { key: "surface", description: "linux-surface kernel + iptsd for Surface devices" },

  // Apps / runtimes
  { key: "steam", description: "Steam + Proton" },
  { key: "docker", description: "docker daemon" },

  // Family / restricted-user features
  { key: "timekpr", description: "screen-time controls (kid accounts)" },
  { key: "chrome-managed", description: "Chrome with Family-Link managed policies" },
];

// Returns true if `name` is a known toggleable feature. Anything
// unknown is silently dropped from the comma-list — keeps stale
// env vars from old wizard runs from leaking through.
export function isKnownFeature(name: string): boolean {
  return AVAILABLE_FEATURES.some((f) => f.key === name);
}
