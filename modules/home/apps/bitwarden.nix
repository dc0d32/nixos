{ pkgs, lib, variables, ... }:
let
  cfg = variables.apps.bitwarden or { enable = false; };
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  hasDesktop = isLinux && !(variables.wsl.enable or false);
in
lib.mkIf ((cfg.enable or false) && isLinux) {
  home.packages = [ pkgs.bitwarden-desktop ];

  # Pre-configure the self-hosted server endpoint so the client doesn't
  # require manual setup on first launch.
  # Retire if Bitwarden ever exposes this via a proper CLI flag or env var.
  xdg.configFile."Bitwarden/appconfig.json".text = builtins.toJSON {
    environmentUrls = {
      base = "https://bitwarden.bitset.cc";
    };
  };

  # Start minimized to tray on desktop sessions.
  programs.niri.settings.spawn-at-startup = lib.mkIf hasDesktop [
    { command = [ "${pkgs.bitwarden-desktop}/bin/bitwarden" "--silent" ]; }
  ];
}
