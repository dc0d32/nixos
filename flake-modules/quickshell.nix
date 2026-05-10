# Quickshell — QtQuick-based Wayland shell (bar, lockscreen, OSDs,
# notifications, flyouts). Config lives in QML under
# ~/.config/quickshell/, deployed from ./qml in this module so the files
# stay real QML (editor highlighting, hot reload) instead of nix-embedded
# strings.
#
# Pattern A: importing this module IS enabling it (legacy
# `desktop.quickshell.enable` gate dropped). Reads `biometrics.enable`
# (published as a signal by flake-modules/biometrics.nix) to set the
# QUICKSHELL_LOCK_FACE / QUICKSHELL_LOCK_FINGERPRINT env vars that
# LockScreen.qml uses to decide which auth methods to advertise.
#
# Two-class module:
#   - flake.modules.homeManager.quickshell — QML deployment, niri spawn
#     entry, runtime env. Imported by every desktop host's HM bundle
#     (flake-modules/bundles/home-{desktop,kid}.nix).
#   - flake.modules.nixos.quickshell      — security.pam.services.
#     quickshell-password. The lockscreen always offers a password
#     prompt (regardless of biometrics availability); without this PAM
#     service the prompt would silently reject every input. Each
#     desktop host bridge MUST import this module — there is no
#     `enable` flag, importing IS enabling. The companion biometric
#     PAM service (quickshell-biometric) is owned by
#     flake-modules/biometrics.nix and only exists on hosts that opt
#     into biometrics; LockContext.qml gates its PamContext on the
#     QUICKSHELL_LOCK_FACE / QUICKSHELL_LOCK_FINGERPRINT env vars so
#     non-biometric hosts don't busy-loop a missing PAM service.
#
# Retire when: quickshell is replaced (waybar, eww, ags, …) or the QML
# tree grows large enough to live in its own repo.
{ config, ... }:
{
  flake.modules.nixos.quickshell = { pkgs, ... }: {
    # Password-only PAM service for the quickshell lockscreen. pam_unix
    # verifies the typed password; pam_gnome_keyring captures the token
    # so the login keyring unlocks on success. No biometrics here —
    # LockContext.qml drives a separate PamContext for the biometric
    # stack (security.pam.services.quickshell-biometric in
    # flake-modules/biometrics.nix) so the two run concurrently.
    #
    # IMPORTANT: PAM resolves bare module names (`pam_unix.so`)
    # relative to linux-pam's own lib/security/ directory. Modules
    # from other packages (gnome-keyring) live in their own store
    # paths and MUST be referenced absolutely or PAM logs "unable to
    # dlopen ... cannot open shared object file" and treats the rule
    # as a faulty module (fails closed). The standard NixOS PAM
    # services (login/sudo/ly) avoid this because their
    # `rules.auth.<name>` entries are auto-prefixed with the right
    # store path; raw `text =` stacks must do it themselves.
    security.pam.services.quickshell-password.text = ''
      auth      required  pam_unix.so       likeauth nullok try_first_pass
      auth      optional  ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so use_authtok
      account   required  pam_unix.so
      password  required  pam_unix.so       sha512 shadow nullok try_first_pass
      password  optional  ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so use_authtok
      session   required  pam_unix.so
      session   optional  ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so auto_start
    '';
  };

  flake.modules.homeManager.quickshell = { lib, pkgs, ... }: {
    home.packages = with pkgs; [
      quickshell
      qt6.qtdeclarative
      qt6.qtsvg
      qt6.qt5compat # for some QML modules used by widgets
      material-symbols # icon font used by widgets
    ];

    xdg.configFile."quickshell" = {
      source = ./quickshell/qml;
      recursive = true;
    };

    home.sessionVariables = {
      QT_QPA_PLATFORM = "wayland";
      QT_WAYLAND_USE_PRIVATE_API = "1";
      # LockScreen.qml reads these to decide which auth methods to
      # advertise in the status hint ("Password, face, or fingerprint"
      # etc). They are set from the host's biometrics.enable signal
      # (set by mkDefault inside flake-modules/biometrics.nix when
      # that module is imported). LockContext.qml ALSO uses these to
      # decide whether to start the biometric PamContext at all — on
      # hosts without biometrics both vars are empty, the
      # quickshell-biometric PAM service doesn't exist, and the
      # PamContext stays dormant so the lockscreen runs password-only.
      # The password PAM service (security.pam.services.
      # quickshell-password) is owned by this file's NixOS-side
      # module above; the biometric one is owned by
      # flake-modules/biometrics.nix.
      QUICKSHELL_LOCK_FACE = if config.biometrics.enable then "1" else "";
      QUICKSHELL_LOCK_FINGERPRINT = if config.biometrics.enable then "1" else "";
    };

    # easyeffects is intentionally NOT spawned here; the canonical owner
    # is `systemd.user.services.easyeffects` in flake-modules/audio.nix
    # (Restart=always, primary GApplication, owns the unix socket and
    # runs DSP). If we ALSO spawn `easyeffects --gapplication-service`
    # from niri, the niri-spawned process wins the race, then the
    # systemd unit's `easyeffects --hide-window` invocation finds the
    # primary already on the bus, hands off as a remote, and exits
    # cleanly. Restart=always then loops it 10x and trips
    # StartLimitBurst, leaving the unit failed even though DSP is
    # actually running. One owner, no race.
    programs.niri.settings.spawn-at-startup = lib.mkAfter [
      { command = [ "quickshell" ]; }
    ];
  };
}
