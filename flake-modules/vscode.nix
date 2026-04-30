# Visual Studio Code (Microsoft's signed builds, unfree).
#
# Pattern A: hosts opt in by importing this module.
#
# Migrated from modules/home/editor/vscode.nix.
{ ... }:
{
  flake.modules.homeManager.vscode = { pkgs, ... }: {
    programs.vscode = {
      enable = true;
      package = pkgs.vscode;
      mutableExtensionsDir = true;
    };

    # Same Wayland subsurface input-region bug as Chrome — VSCode is
    # Electron (Chromium-based) and exhibits the same missed-click
    # issue under niri with prefer-no-csd. Disable
    # WaylandWindowDecorations to use a single surface.
    # Retire when the upstream Chromium bug is fixed.
    xdg.configFile."code-flags.conf".text = ''
      --disable-features=WaylandWindowDecorations
    '';
  };
}
