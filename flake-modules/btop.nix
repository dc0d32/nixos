# btop — cross-platform system / process monitor with TTY-friendly theme.
#
# Migrated from modules/home/tools/btop.nix.
{
  flake.modules.homeManager.btop = {
    programs.btop = {
      enable = true;
      settings = {
        color_theme = "TTY";
        theme_background = false;
        vim_keys = true;
        rounded_corners = true;
        update_ms = 1000;
      };
    };
  };
}
