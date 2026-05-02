# ly — a tiny TUI login manager. Lightweight, no Qt/GTK, looks great
# on a fresh terminal, works fine for launching niri (Wayland session).
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
        animation = "matrix";
        clock = "%F  %T";
        clear_password = true;
        hide_borders = false;
        blank_box = true;
        bigclock = true;
      };
    };
  };
}
