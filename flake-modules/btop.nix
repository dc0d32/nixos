# btop — cross-platform system / process monitor with TTY-friendly theme.
#
# Retire when: btop is no longer used / dropped from the daily workflow,
#   or replaced by a different process monitor (e.g. htop, bottom).
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
