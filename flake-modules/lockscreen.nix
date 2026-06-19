# Lockscreen — swaylock(-effects). PAM stack + per-user config.
#
# Cross-class:
#   - NixOS side: security.pam.services.swaylock — password-ONLY auth.
#     fprintd + howdy are explicitly stripped (they are auto-wired into
#     every PAM service by services.{fprintd,howdy}.enable; on the
#     lockscreen that broke password unlock — see the body comment and
#     the 2026-06-18 session log). The screen must always unlock with a
#     password; biometrics deliberately do NOT apply here.
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
  flake.modules.nixos.lockscreen = { lib, ... }: {
    # The lockscreen declares its OWN auth policy: password only.
    #
    # Both services.fprintd.enable and services.howdy.enable auto-wire
    # pam_fprintd + pam_howdy as `sufficient` into EVERY pam service,
    # including swaylock. biometrics.nix reorders those for
    # sudo/login/ly/bitwarden but not swaylock, so the lockscreen used
    # to inherit `fprintd → howdy → unix(try_first_pass) → deny`. With
    # no fingerprints enrolled and pam_howdy clobbering PAM_AUTHTOK
    # before the try_first_pass pam_unix, the correct password was
    # rejected as "invalid credentials" (see the 2026-06-18 session
    # log). Earlier unix-early / allowNullPassword hacks fought the
    # symptom; this removes the cause.
    #
    # Stripping both biometrics leaves swaylock with `pam_unix →
    # pam_deny` — deterministic, and immune to any future biometric
    # change. Password must always unlock the screen; face/fingerprint
    # still work for login/sudo/ly via their own (reordered) stacks.
    security.pam.services.swaylock = {
      fprintAuth = lib.mkForce false;
      howdy.enable = lib.mkForce false;
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
