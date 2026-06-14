# Lockscreen — swaylock(-effects). PAM stack + per-user config.
#
# Cross-class:
#   - NixOS side: security.pam.services.swaylock so the unlock prompt
#     accepts the user's password. fprintAuth = true so on biometric
#     hosts the fingerprint sensor also unlocks the screen.
#   - HM side: install swaylock-effects + drop a config file.
#
# Pattern A: hosts opt in by importing. Importing IS enabling.
#
# Replaces the quickshell-based lockscreen (deleted along with the
# rest of the QML tree). Trade-off accepted at retreat time: no face
# unlock on the lockscreen anymore (howdy + swaylock is not a thing
# anyone has wired), only password and fingerprint. fprintd's PAM
# module runs in parallel with pam_unix so fingerprint and password
# both race for a winner; whichever returns success first unlocks.
#
# Lock is invoked by:
#   - niri keybind Super+Alt+L              (see flake-modules/niri.nix)
#   - idled stage "lock" timeout            (see flake-modules/idle.nix)
#   - idled lock_before_sleep pre-suspend   (see flake-modules/idle.nix)
#
# Retire when: a future compositor ships its own lockscreen, or you
# go back to a custom shell.
{ lib, ... }:
{
  flake.modules.nixos.lockscreen = { ... }: {
    # NixOS auto-prepends the correct linux-pam store path for
    # pam_unix and pam_fprintd, so we don't spell module paths
    # explicitly here. `fprintAuth = true` slots pam_fprintd into
    # the auth substack at the host-wide order; on hosts without
    # fprintd enabled (m-pc), the rule short-circuits to "ignore"
    # and the prompt is password-only.
    security.pam.services.swaylock = {
      fprintAuth = lib.mkDefault true;
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
