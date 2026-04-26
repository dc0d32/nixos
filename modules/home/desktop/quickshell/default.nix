{ lib, pkgs, variables, ... }:
let cfg = variables.desktop.quickshell or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  # Quickshell is a QtQuick-based Wayland shell. Config lives in QML under
  # ~/.config/quickshell/, loaded from ./qml in this module so the files stay
  # real QML (editor highlighting, hot reload) instead of nix-embedded strings.
  home.packages = with pkgs; [
    quickshell
    qt6.qtdeclarative
    qt6.qtsvg
    qt6.qt5compat # for some QML modules used by widgets
    material-symbols # icon font used by widgets
  ];

  xdg.configFile."quickshell" = {
    source = ./qml;
    recursive = true;
  };

  home.sessionVariables = {
    QT_QPA_PLATFORM = "wayland";
    QT_WAYLAND_USE_PRIVATE_API = "1";
  };

  programs.niri.settings.spawn-at-startup = lib.mkAfter [
    { command = [ "quickshell" ]; }
  ];
}
