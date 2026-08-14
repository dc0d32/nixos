# ly — a tiny true-colour TUI login manager. Lightweight, no Qt/GTK,
# with a built-in animated aurora-style backdrop and large clock.
#
# Pattern A: hosts opt in by importing this module. Headless / WSL
# hosts simply don't import it.
#
# Niri (or any other Wayland/X session module) provides its own
# wayland-sessions/.desktop entry; ly will list whatever's available
# automatically.
#
# Retire when: ly is replaced by a different display manager (gdm,
#   sddm, greetd+tuigreet) on every host that imports it, OR auto-login
#   straight into the Wayland session removes the need for a DM at all.
{ ... }:
{
  flake.modules.nixos.login-ly = { lib, ... }: {
    # Use only one DM; default the others off so any future host
    # enabling gdm/sddm/lightdm only has to flip its own switch
    # (mkDefault loses to any explicit assignment in the host
    # config).
    # Note: gdm/sddm live under services.displayManager.* in current
    # nixpkgs, but lightdm is still at
    # services.xserver.displayManager.lightdm.
    services.displayManager.gdm.enable = lib.mkDefault false;
    services.displayManager.sddm.enable = lib.mkDefault false;
    services.xserver.displayManager.lightdm.enable = lib.mkDefault false;

    services.displayManager.ly = {
      enable = true;
      settings = {
        # xinitrc = "null" tells ly to hide its built-in X11 "xinitrc"
        # picker entry (ly parses the literal string `null` as
        # "hidden", per its res/config.ini comment). Without this,
        # the session picker reads
        #   [shell, xinitrc, niri]
        # and lands on index 0 = the hardcoded "shell" pseudo-entry
        # on every boot (ly's own `save = true` is non-functional on
        # NixOS because it writes to /etc which is RO). Suppressing
        # xinitrc collapses the picker to [shell, niri], so a single
        # Down arrow selects the only real desktop. The "shell" entry
        # itself is hardcoded into ly and cannot be removed without
        # patching upstream.
        xinitrc = "null";
        # A slow Nordic colour wash gives the TTY some atmosphere without
        # replacing ly with a graphical display manager.
        animation = "colormix";
        animation_frame_delay = 24;
        colormix_col1 = "0x005E81AC";
        colormix_col2 = "0x0088C0D0";
        colormix_col3 = "0x00D08770";

        bg = "0x002E3440";
        fg = "0x00ECEFF4";
        border_fg = "0x0188C0D0";
        error_fg = "0x01BF616A";

        clock = "%F  %T";
        clear_password = true;
        hide_borders = false;
        hide_version_string = true;
        blank_box = false;
        box_title = "Welcome home";
        bigclock = "en";
        bigclock_seconds = false;
        text_in_center = true;
      };
    };
  };
}
