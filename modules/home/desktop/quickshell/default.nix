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
    # LockScreen.qml reads these to decide which auth methods to advertise
    # in the status hint ("Password, face, or fingerprint" etc). They are
    # set from the host's variables.biometrics flag — the actual PAM stacks
    # (quickshell-{password,biometric}) are wired up unconditionally in
    # modules/nixos/biometrics.nix when biometrics.enable is true.
    QUICKSHELL_LOCK_FACE        = if (variables.biometrics.enable or false) then "1" else "";
    QUICKSHELL_LOCK_FINGERPRINT = if (variables.biometrics.enable or false) then "1" else "";
  };

  programs.niri.settings.spawn-at-startup = lib.mkAfter [
    { command = [ "easyeffects" "--gapplication-service" ]; }
    { command = [ "quickshell" ]; }
  ];
}
