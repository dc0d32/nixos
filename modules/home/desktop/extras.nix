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

    # Qt theming
    kdePackages.qt6ct
    catppuccin-qt5ct

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

  # ── GTK theming ──────────────────────────────────────────────────────────
  gtk = {
    enable = true;
    theme = {
      package = pkgs.catppuccin-gtk.override { variant = "mocha"; accents = [ "blue" ]; };
      name = "catppuccin-mocha-blue-standard+default";
    };
    iconTheme = {
      package = pkgs.papirus-icon-theme;
      name = "Papirus-Dark";
    };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
    gtk4 = {
      extraConfig.gtk-application-prefer-dark-theme = true;
      theme = null; # adopt new default; GTK4 apps use color-scheme via dconf instead
    };
  };

  # Tell libadwaita/GTK4 apps to use dark color scheme via dconf.
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";

  # ── Qt theming ───────────────────────────────────────────────────────────
  qt = {
    enable = true;
    platformTheme.name = "qtct";
    style = {
      name = "qt6ct-style";
      package = pkgs.catppuccin-qt5ct;
    };
  };

  # ── Cursor theme ─────────────────────────────────────────────────────────
  # Bibata Modern Classic: black/white, color only on animated frames.
  # Retire if cursor preference changes.
  home.pointerCursor = {
    package = pkgs.bibata-cursors;
    name = "Bibata-Modern-Classic";
    size = 16;
    gtk.enable = true;
    x11.enable = true;
  };

  # Configure qt6ct to use Catppuccin Mocha Blue color scheme.
  xdg.configFile."qt6ct/qt6ct.conf" = {
    force = true;
    text = ''
      [Appearance]
      color_scheme_path=${pkgs.catppuccin-qt5ct}/share/qt6ct/colors/catppuccin-mocha-blue.conf
      custom_palette=true
      icon_theme=Papirus-Dark
      style=Fusion
    '';
  };

  # systemd user socket-activated ssh-agent. Keys are added on first use.
  # Retire if a hardware key (YubiKey) or secret manager handles SSH instead.
  services.ssh-agent.enable = lib.mkDefault (variables.sshAgent.enable or true);

  home.sessionVariables = {
    QT_QPA_PLATFORM = "wayland";
  } // lib.optionalAttrs (variables.sshAgent.enable or true) {
    SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent.socket";
  };
}
