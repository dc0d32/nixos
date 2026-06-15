# Lockscreen — swaylock(-effects). PAM stack + per-user config.
#
# Cross-class:
#   - NixOS side: security.pam.services.swaylock so the unlock prompt
#     accepts the user's password. fprintAuth is OFF by default —
#     password must always unlock without touching the fingerprint
#     sensor. Hosts that want fingerprint unlock can set
#     `security.pam.services.swaylock.fprintAuth = true;` in their
#     bridge ONLY after fingerprints are enrolled; pam_fprintd blocks
#     the PAM conversation waiting for a swipe on hosts where no
#     fingerprints are registered, making swaylock appear hung.
#   - HM side: install swaylock-effects + drop a config file.
#
# Pattern A: hosts opt in by importing. Importing IS enabling.
#
# Replaces the quickshell-based lockscreen (deleted along with the
# rest of the QML tree). Trade-off accepted at retreat time: no face
# unlock on the lockscreen (howdy + swaylock is not a thing anyone
# has wired). Face still works for sudo/login/ly.
#
# Lock is invoked by:
#   - niri keybind Super+Alt+L              (see flake-modules/niri.nix)
#   - idled stage "lock" timeout            (see flake-modules/idle.nix)
#   - idled lock_before_sleep pre-suspend   (see flake-modules/idle.nix)
#
# Retire when: a future compositor ships its own lockscreen, or you
# go back to a custom shell.
{ ... }:
{
  flake.modules.nixos.lockscreen = { config, ... }: {
    # NixOS auto-prepends the correct linux-pam store path for
    # pam_unix. fprintAuth is deliberately left false (the default)
    # so password unlock always works. To enable fingerprint unlock
    # on a specific host, add to its bridge AFTER enrolling prints:
    #   security.pam.services.swaylock.fprintAuth = true;
    security.pam.services.swaylock = {
      allowNullPassword = true;

      # Add an early optional pam_unix before howdy to initialize the
      # PAM_AUTHTOK buffer. Without this, howdy can interfere with
      # the auth token and cause pam_unix's try_first_pass to fail.
      # See docs/sessions/2026-04-29-idle-lock-fix.md for background
      # on serial PAM bugs and why this matters.
      rules.auth."unix-early" = {
        control = "optional";
        order = 0;
        modulePath = "${config.security.pam.package}/lib/security/pam_unix.so";
        settings = {
          nullok = true;
          likeauth = true;
        };
      };
    };
  };

  flake.modules.homeManager.lockscreen = { pkgs, ... }: {
    home.packages = [ pkgs.swaylock-effects ];

    # `daemonize` makes `swaylock` return immediately after the
    # locker has acquired the session-lock surface — important for
    # idled / niri-keybind invocations that shouldn't block.
    xdg.configFile."swaylock/config".text = ''
      ignore-empty-password
      show-failed-attempts
      daemonize
      indicator
      indicator-radius=120
      indicator-thickness=10
      effect-blur=12x4
      ring-color=2e3440
      key-hl-color=88c0d0
      bs-hl-color=bf616a
      separator-color=2e3440
      text-color=eceff4
      text-clear-color=eceff4
      text-ver-color=eceff4
      text-wrong-color=eceff4
      inside-color=2e344088
      inside-clear-color=2e344088
      inside-ver-color=88c0d088
      inside-wrong-color=bf616a88
      line-color=2e3440
      line-clear-color=88c0d0
      line-ver-color=88c0d0
      line-wrong-color=bf616a
      ring-clear-color=88c0d0
      ring-ver-color=88c0d0
      ring-wrong-color=bf616a
    '';
  };
}
