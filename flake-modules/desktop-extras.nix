# Desktop extras: clipboard, screenshot annotation, screen recording,
# GTK/Qt theming, cursor theme, file/image/video viewers, notifications.
#
# Migrated from modules/home/desktop/extras.nix. Pattern A: importing this
# module IS enabling it; the legacy `desktop.niri.enable` gate is dropped
# (hosts that don't want desktop tools simply don't import this module).
#
# The legacy ssh-agent block was tied to variables.sshAgent.enable=false on
# the laptop; not migrated. If a future host needs it, add a separate
# ssh-agent feature module rather than coupling it to desktop extras.
#
# Retire when: laptop drops Wayland desktop or these tools are split into
# per-concern modules (theming, clipboard, viewers, etc.).
{
  flake.modules.homeManager.desktop-extras = { pkgs, ... }: {
    # ── Packages ─────────────────────────────────────────────────────────────
    home.packages = with pkgs; [
      # Screenshots
      satty # annotation tool (region → annotate → copy/save)

      # Clipboard
      cliphist # clipboard history daemon
      wl-clipboard # wl-copy / wl-paste (also used by satty --copy-command)

      # Screen recording
      wf-recorder # wlroots screencast recorder

      # Qt theming
      kdePackages.qt6ct
      catppuccin-qt5ct

      # File manager (lightweight, no GNOME dep)
      yazi # terminal file manager

      # Image viewer
      imv # minimal Wayland image viewer

      # Video player
      vlc
      mpv

      # Notifications
      libnotify # provides notify-send for testing / scripting
    ];

    # ── GTK theming ──────────────────────────────────────────────────────────
    gtk = {
      enable = true;
      theme = {
        package = pkgs.catppuccin-gtk.override {
          variant = "mocha";
          accents = [ "blue" ];
        };
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

    home.sessionVariables = {
      QT_QPA_PLATFORM = "wayland";
    };
  };
}
