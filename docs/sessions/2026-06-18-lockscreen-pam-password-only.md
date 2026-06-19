# 2026-06-18 — lockscreen: strip biometric PAM pollution (password-only)

**Change:** swaylock's PAM service now declares its own auth policy —
`pam_unix → pam_deny`, password only. `fprintAuth` and `howdy.enable`
are forced off for swaylock; the earlier `unix-early` /
`allowNullPassword` band-aids are removed.

## Symptom

After the impermanence password rework + a reboot, the lockscreen
rejected the correct password. Not a hang — the journal showed an
outright reject:

```
swaylock[…]: pam_unix(swaylock:auth): authentication failure … user=p
idled[…]:  pam_authenticate failed: invalid credentials
```

`su - p` with the same password succeeded, proving the hash was fine
and the fault was the swaylock PAM stack.

## Root cause

`services.fprintd.enable` and `services.howdy.enable` auto-wire
`pam_fprintd` and `pam_howdy` as `auth sufficient` into **every** PAM
service (fprintAuth defaults to `services.fprintd.enable`; the howdy
module wires `pam_howdy` similarly). `biometrics.nix` carefully
reorders these around `pam_unix` for `sudo` / `login` / `ly` /
`bitwarden` — but **swaylock was never in that list**, so it inherited
the naive default stack:

```
auth optional  pam_unix.so  likeauth nullok            # unix-early (0)  ← band-aid
auth sufficient pam_fprintd.so                         # fprintd (11400) ← p has NO prints enrolled
auth sufficient pam_howdy.so                           # howdy (11500)   ← face unlock nobody wanted here
auth sufficient pam_unix.so  likeauth nullok try_first_pass # unix (11700)
auth required  pam_deny.so                             # deny (12500)
```

`pam_howdy` runs between `unix-early` and the real `pam_unix`, and
clobbers `PAM_AUTHTOK`; the final `pam_unix` with `try_first_pass` then
checks the wrong token → "invalid credentials". The `unix-early` hack
(an earlier fix) tried to out-order howdy instead of removing it, so it
only papered over the problem and regressed whenever the biometric
config changed.

## Why not switch lockers

hyprlock / gtklock / any swaylock alternative all authenticate through
PAM and would inherit the **same** polluted stack. The locker was never
the problem; the PAM service was. So the fix is independent of locker
choice, and we kept swaylock-effects.

## Fix

`lockscreen.nix` now sets, on the NixOS side:

```nix
security.pam.services.swaylock = {
  fprintAuth = lib.mkForce false;     # strips pam_fprintd
  howdy.enable = lib.mkForce false;   # strips pam_howdy
};
```

`mkForce` because both default to the global biometric enables
(`services.fprintd.enable` / `security.pam.howdy.enable`), which are
`true` on these hosts. The result, verified on the built system for
pb-x1 / m-pc / pb-t480:

```
auth sufficient pam_unix.so likeauth try_first_pass  # unix (11700)
auth required  pam_deny.so                           # deny (12500)
```

Deterministic, password-only, and immune to future biometric changes.
Face + fingerprint still work for login / sudo / ly via their own
(reordered) stacks; only the lockscreen is biometric-free — matching
this module's long-stated design intent ("password must always unlock;
no face unlock on the lockscreen").

## Design lesson

biometrics.nix de-pollutes the global fprintd/howdy auto-wiring by
**enumerating** the services it cares about. Any PAM service it doesn't
name silently inherits the broken `fprintd → howdy → unix` default.
A service that wants a specific auth policy (like the lockscreen) must
declare it explicitly rather than trusting the inherited default. If
more services hit this, consider having biometrics.nix default ALL
non-listed services to password-first instead of enumerating.

## Apply

`sudo nixos-rebuild switch --flake .#pb-x1`, then test: lock with
Super+Alt+L and unlock with your password. No reboot needed.
