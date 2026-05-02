# Firefox — additional browser for adult/admin accounts.
#
# WHY: Kept alongside chrome (not replacing it) because some sites
# only behave well in Chromium-engine browsers and chrome stays
# useful for testing the kid-managed-policy view. Firefox is the
# preferred default daily driver where it works, with chrome as a
# fallback.
#
# Pattern A: hosts opt in by importing this module (via the
# desktop bundle for adult accounts).
#
# Linux only here. nixpkgs ships firefox for darwin too, but no
# darwin host currently consumes the desktop bundle, so leaving
# the platform guard out keeps this simple. Add a guard if a
# darwin host ever imports it.
#
# Retire when: firefox is no longer wanted on any host, or replaced
#   by a different non-chromium browser (e.g. librewolf, zen).
{ ... }:
{
  flake.modules.homeManager.firefox = { pkgs, ... }: {
    home.packages = [ pkgs.firefox ];

    # Wayland-native rendering. firefox has read MOZ_ENABLE_WAYLAND
    # automatically since ~v121, but setting it explicitly avoids
    # any future regression on the auto-detect path. Harmless on
    # X11 sessions (firefox falls back to X when no wayland socket
    # is present).
    home.sessionVariables = {
      MOZ_ENABLE_WAYLAND = "1";
    };
  };
}
