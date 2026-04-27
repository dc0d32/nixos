{ pkgs, lib, variables, ... }:
# Desktop extras: clipboard manager, screenshot annotation,
# screen recording, GTK/cursor/icon theming, XDG mime defaults, SSH agent.
# All gated on desktop.niri.enable since these are Wayland/desktop-only.
let
  cfg = variables.desktop.niri or { enable = false; };
  enabled = cfg.enable or false;
in
lib.mkIf enabled {

  # ── Packages ─────────────────────────────────────────────────────────────
  home.packages = with pkgs; [
    # Screenshots
    satty             # annotation tool (region → annotate → copy/save)

    # Clipboard
    cliphist          # clipboard history daemon
    wl-clipboard      # wl-copy / wl-paste (also used by satty --copy-command)

    # Screen recording
    wf-recorder       # wlroots screencast recorder

    # GTK / icon theme
    (catppuccin-gtk.override { variant = "mocha"; accents = [ "blue" ]; })
    papirus-icon-theme

    # File manager (lightweight, no GNOME dep)
    yazi              # terminal file manager

    # Image viewer
    imv               # minimal Wayland image viewer

    # Video player
    vlc
    mpv

    # Notifications
    libnotify         # provides notify-send for testing / scripting
  ];

  # ── Cursor theme ─────────────────────────────────────────────────────────
  # Catppuccin Mocha Blue cursor, 16px. Retire if theme preference changes.
  home.pointerCursor = {
    package = pkgs.catppuccin-cursors.mochaBlue;
    name = "catppuccin-mocha-blue-cursors";
    size = 16;
    gtk.enable = true;
    x11.enable = true;
  };

  # ── SSH agent ─────────────────────────────────────────────────────────────
  # systemd user socket-activated ssh-agent. Keys are added on first use.
  # Retire if a hardware key (YubiKey) or secret manager handles SSH instead.
  services.ssh-agent.enable = lib.mkDefault (variables.sshAgent.enable or true);

  home.sessionVariables = lib.mkIf (variables.sshAgent.enable or true) {
    SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent.socket";
  };
}
