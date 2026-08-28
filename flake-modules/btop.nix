# btop — cross-platform system / process monitor with TTY-friendly theme.
#
# The settings are published as `flake.lib.btopSettings` and reused by
# flake-modules/windows for btop4win, so the Linux and Windows monitors
# look the same. See that module for the one key it drops (iowait, which
# Windows doesn't expose).
#
# Retire when: btop is no longer used / dropped from the daily workflow,
#   or replaced by a different process monitor (e.g. htop, bottom).
let
  settings = {
    color_theme = "TTY";
    theme_background = false;
    vim_keys = true;
    rounded_corners = true;
    update_ms = 1000;
    # Lower CPU graph shows I/O-wait (upper stays total) — makes disk/IO
    # stalls obvious at a glance. Linux-only (see windows module).
    cpu_graph_lower = "iowait";
  };
in
{
  flake.lib.btopSettings = settings;

  flake.modules.homeManager.btop = {
    programs.btop = {
      enable = true;
      inherit settings;
    };
  };
}
