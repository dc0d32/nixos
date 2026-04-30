# waybar — top status bar (alternative to quickshell). Currently
# disabled on the laptop (quickshell is enabled instead) but kept
# around as a working config for fallback / debugging.
#
# Pattern A: hosts opt in by importing this module. The "pick ONE
# status bar / shell" rule from variables.nix is now expressed by
# importing either this OR quickshell, never both.
#
# Migrated from modules/home/desktop/waybar.nix.
{ ... }:
{
  flake.modules.homeManager.waybar = {
    programs.waybar = {
      enable = true;
      settings.mainBar = {
        layer = "top";
        position = "top";
        height = 28;
        modules-left = [ "niri/workspaces" ];
        modules-center = [ "clock" ];
        modules-right = [ "pulseaudio" "network" "battery" "tray" ];
        clock.format = "{:%a %Y-%m-%d  %H:%M}";
      };
    };
  };
}
