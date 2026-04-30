# Quickshell — QtQuick-based Wayland shell (bar, lockscreen, OSDs,
# notifications, flyouts). Config lives in QML under
# ~/.config/quickshell/, deployed from ./qml in this module so the files
# stay real QML (editor highlighting, hot reload) instead of nix-embedded
# strings.
#
# Migrated from modules/home/desktop/quickshell/{default.nix,qml/}.
# Pattern A: importing this module IS enabling it (legacy
# `desktop.quickshell.enable` gate dropped). Reads `biometrics.enable`
# (published as a signal by flake-modules/biometrics.nix) to set the
# QUICKSHELL_LOCK_FACE / QUICKSHELL_LOCK_FINGERPRINT env vars that
# LockScreen.qml uses to decide which auth methods to advertise.
#
# Retire when: quickshell is replaced (waybar, eww, ags, …) or the QML
# tree grows large enough to live in its own repo.
{ config, ... }:
{
  flake.modules.homeManager.quickshell = { lib, pkgs, ... }: {
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
      # set from the host's biometrics.enable signal (set by mkDefault inside
      # flake-modules/biometrics.nix when that module is imported). The
      # actual PAM stacks (quickshell-{password,biometric}) are wired up
      # unconditionally in flake-modules/biometrics.nix.
      QUICKSHELL_LOCK_FACE = if config.biometrics.enable then "1" else "";
      QUICKSHELL_LOCK_FINGERPRINT = if config.biometrics.enable then "1" else "";
    };

    programs.niri.settings.spawn-at-startup = lib.mkAfter [
      { command = [ "easyeffects" "--gapplication-service" ]; }
      { command = [ "quickshell" ]; }
    ];
  };
}
