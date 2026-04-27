{ pkgs, lib, variables, ... }:
let
  cfg = variables.apps.vscode or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
    mutableExtensionsDir = true;
  };

  # Same Wayland subsurface input-region bug as Chrome — VSCode is Electron
  # (Chromium-based) and exhibits the same missed-click issue under niri with
  # prefer-no-csd.  Disable WaylandWindowDecorations to use a single surface.
  # Retire when the upstream Chromium bug is fixed.
  xdg.configFile."code-flags.conf".text = ''
    --disable-features=WaylandWindowDecorations
  '';
}
