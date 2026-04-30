# Bitwarden desktop client.
#
# Pre-configures the self-hosted server endpoint so the client
# doesn't require manual setup on first launch. Spawns the client
# minimized to tray at niri startup.
#
# Pattern A: hosts opt in by importing this module. Linux only —
# darwin hosts skip importing.
#
# Cross-class note: the matching NixOS-side polkit policy that pipes
# Bitwarden unlock through the biometric PAM stack lives in
# flake-modules/biometrics.nix (security.polkit.extraConfig +
# security.pam.services.bitwarden), because it must register at the
# system level for polkit to find it.
#
# Migrated from modules/home/apps/bitwarden.nix.
{ ... }:
{
  flake.modules.homeManager.bitwarden = { pkgs, ... }: {
    home.packages = [ pkgs.bitwarden-desktop ];

    # Pre-configure the self-hosted server endpoint so the client
    # doesn't require manual setup on first launch.
    # Retire if Bitwarden ever exposes this via a proper CLI flag or
    # env var.
    xdg.configFile."Bitwarden/appconfig.json".text = builtins.toJSON {
      environmentUrls = {
        base = "https://bitwarden.bitset.cc";
      };
    };

    # Start minimized to tray at niri startup.
    programs.niri.settings.spawn-at-startup = [
      { command = [ "${pkgs.bitwarden-desktop}/bin/bitwarden" "--silent" ]; }
    ];
  };
}
