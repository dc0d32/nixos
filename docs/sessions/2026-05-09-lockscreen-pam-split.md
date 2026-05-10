# 2026-05-09 — Lockscreen PAM split: own quickshell-password from quickshell.nix

Brought up a third real host (m-pc, the Compaq Pro 4300 SFF kids'
desktop) and discovered its quickshell lockscreen silently rejected
every password. Root cause was an architectural coupling that had
been latent since the dual-PamContext lockscreen design landed in
April: the password PAM service was owned by the biometrics module,
which non-biometric desktop hosts deliberately don't import.

## What landed

Two commits on `main`:

| SHA | Title |
|---|---|
| `78ff6cd` | quickshell: own quickshell-password PAM service; gate biometric stack |
| `a32ab62` | quickshell/lock: drop dead stasis pause/resume calls |

## Decisions (asked, not assumed)

- **Scope of the fix.** Three options on the table:
  1. Move `quickshell-password` to a module that every desktop host
     imports + gate the biometric PamContext on biometrics
     availability + drop the dead stasis calls (the architectural
     fix; **chosen**).
  2. Have m-pc import `biometrics.nix` wholesale. Ships
     services.fprintd / services.howdy / IR-camera-autodetect to a
     desktop with no fingerprint reader and no IR camera. They'd
     no-op but it's wasteful and conceptually wrong ("why does the
     kids' desktop run face-auth services?").
  3. Patch the QML to gate the biometric stack AND duplicate
     `security.pam.services.quickshell-password` inline on m-pc.
     Spreads the same PAM stack definition across two files —
     fragile if it diverges.

  Picked option 1: clean ownership, scales to any future
  non-biometric host (server console, headless box that grows a
  display, etc.) without the per-host plumbing of option 3 or the
  conceptual mismatch of option 2.
- **Where the password PAM service lives.** Two candidates:
  1. `flake-modules/quickshell.nix` (chosen). Quickshell is the
     consumer of the PAM service; co-locating server-side and
     client-side wiring in one module mirrors the existing
     `flake.modules.{nixos,homeManager}.niri` two-class pattern.
  2. New `flake-modules/lockscreen.nix` for separate
     concern-of-system-vs-QML. Rejected — the lockscreen is part of
     quickshell's surface, not a discoverable independent feature.

## Background — what the dual-PamContext lockscreen actually does

The quickshell lockscreen runs **two PAM contexts in parallel**:

- `quickshell-password` — `pam_unix` + `pam_gnome_keyring`. Drives
  the always-visible password input box. On success the gnome
  keyring also unlocks (it captures the AUTHTOK).
- `quickshell-biometric` — `pam_howdy` (face) → `pam_fprintd`
  (finger) → `pam_deny`. Runs entirely in the background, never
  prompts for a response. Whichever stack returns success first
  unlocks the session and aborts the other.

A single `PamContext` runs its stack sequentially: with the standard
NixOS login stack the first auth rule is `pam_unix(sufficient)`,
which immediately blocks asking for a password — biometrics only
get a chance after a wrong/missing password fails through. Splitting
into two single-purpose PAM services lets us drive both stacks
concurrently, which is what gives the lockscreen its
"start-typing-immediately-OR-glance-at-the-camera" UX.

## What changed — the architectural fix

### Before

```
flake-modules/biometrics.nix
  └─ security.pam.services.quickshell-password
  └─ security.pam.services.quickshell-biometric
  └─ services.fprintd / services.howdy / camera-autodetect / …
```

A host that wanted the lockscreen but no biometrics had no way to
get the password PAM service without also pulling in fprintd, howdy,
and the IR-camera autodetect oneshot. m-pc's host bridge omitted
biometrics → both PAM services missing → lockscreen unresponsive.

### After

```
flake-modules/quickshell.nix
  ├─ flake.modules.homeManager.quickshell  ← QML deployment, niri
  │                                          spawn entry, env vars
  └─ flake.modules.nixos.quickshell        ← security.pam.services.
                                             quickshell-password
                                             (NEW)

flake-modules/biometrics.nix
  └─ security.pam.services.quickshell-biometric  ← only here
  └─ services.fprintd / services.howdy / …
```

Every desktop host bridge now imports
`config.flake.modules.nixos.quickshell` alongside the existing
`niri` import. Hosts that want biometrics ALSO import
`config.flake.modules.nixos.biometrics` — same as before.

### LockContext.qml gate

The two PamContexts in `LockContext.qml` are still declared
unconditionally (QML doesn't have nice conditional component
instantiation), but `pamBiometric.start()` is now gated on a derived
`biometricsAvailable = faceAvailable || fingerprintAvailable`
property. Both source flags read the
`QUICKSHELL_LOCK_FACE` / `QUICKSHELL_LOCK_FINGERPRINT` env vars,
which `quickshell.nix` sets from `config.biometrics.enable`. On
non-biometric hosts the env vars are empty, the gate is false, and
the biometric PamContext is declared but never `start()`ed — so it
never references the missing PAM service.

The 3 s biometric restart timer also picks up the gate, so we don't
busy-loop trying (and failing) to restart a missing service every
3 s on a non-biometric host.

### Verified PAM-service matrix per host

```
$ for host in pb-x1 m-pc pb-t480 ah-1; do
    for svc in quickshell-password quickshell-biometric; do
      … nix eval … hasAttr svc cfg.security.pam.services …
    done
  done

pb-x1   quickshell-password  = yes
pb-x1   quickshell-biometric = yes
m-pc    quickshell-password  = yes   ← was no, now yes
m-pc    quickshell-biometric = no    ← correct: m-pc has no biometrics module
pb-t480 quickshell-password  = yes
pb-t480 quickshell-biometric = yes
ah-1    quickshell-password  = no    ← correct: headless, no quickshell
ah-1    quickshell-biometric = no
```

Exactly the matrix we want.

## Drive-by: dead stasis calls in LockScreen.qml

`LockScreen.qml`'s `lock()` and `teardown()` shelled out to
`stasis pause` / `stasis resume` via `Quickshell.execDetached(…)` to
keep the idle daemon's DPMS / suspend countdown from firing while
the user was mid-unlock. Stasis was replaced by the in-tree `idled`
daemon on 2026-04-29 (see `docs/sessions/2026-04-29-idle-lock-fix.md`)
and isn't on PATH anymore — both calls have been silently no-op'ing
ever since.

Verified that idled doesn't need an analogous IPC: it watches
logind's `BlockInhibited` flag and `org.freedesktop.ScreenSaver`
inhibits, and detects unlock via fresh input events on its wayland
seat. The lockscreen doesn't need to coordinate with it manually.

Dropped both calls and updated the surrounding comments to mention
the idle daemon by role rather than by name (so we don't have to
revisit this comment if idled is replaced again).

## Why two commits, not one

The PAM-service move + host-bridge wiring + biometric gate are
co-dependent — splitting them would mean intermediate commits with
a broken lockscreen on at least one host. They land atomically as
`78ff6cd`.

The stasis cleanup is independent dead-code removal that touches a
single file (`LockScreen.qml`); it splits cleanly into `a32ab62`
without breaking anything.

## Files touched

Commit `78ff6cd` (architectural fix):

- `flake-modules/quickshell.nix` — new `flake.modules.nixos.quickshell`
  with `security.pam.services.quickshell-password`; updated header
  docstring to document the two-class layout.
- `flake-modules/biometrics.nix` — removed `quickshell-password`
  declaration; kept `quickshell-biometric` with updated comments
  explaining the split ownership.
- `flake-modules/hosts/pb-x1.nix`, `pb-t480.nix`, `m-pc.nix` —
  added `config.flake.modules.nixos.quickshell` to imports list.
- `flake-modules/quickshell/qml/lock/LockContext.qml` —
  `biometricsAvailable` derived flag; gated `pamBiometric.start()`
  in `startAuth()` and the restart timer; updated header docs to
  point at the new home of the PAM service.

Commit `a32ab62` (dead-code cleanup):

- `flake-modules/quickshell/qml/lock/LockScreen.qml` — dropped both
  `Quickshell.execDetached(["stasis", …])` calls; updated
  surrounding comments.

## Verification

- `nix build` (smoke, agent-side, no sudo): pb-x1, pb-t480
  (placeholder), m-pc (placeholder) all build their
  `system.build.toplevel`.
- `nix build` HM: `p@pb-x1.activationPackage` builds.
- `NIXOS_ALLOW_PLACEHOLDER=1 nix flake check --impure`: all
  checks pass, including the pre-commit hook (`no hardcoded
  /bin/bash shebangs`, `gitleaks`, `nixpkgs-fmt`).
- PAM matrix per host verified by `nix eval` with `hasAttr` over
  `security.pam.services` (table above).
- **Not yet** verified on real hardware: m-pc unlock with the
  password PAM service finally present. User to reboot m-pc and
  test the lock + unlock cycle as the next manual step.

## Follow-up notes

- If m-pc's lockscreen still misbehaves after this change, the next
  thing to check is `journalctl -b -u quickshell` for PAM error
  output — with the service finally present, any remaining failure
  should produce a real log line instead of silent rejection.
- The `biometricsAvailable` env-var gate is robust against future
  non-biometric hosts (server console with display, secondary
  desktop without an IR cam, etc.) — they get the lockscreen
  password prompt for free by importing the quickshell module
  alongside niri.
- Architectural rule reinforced: a feature module that owns
  cross-cutting policy (here: a PAM service the lockscreen needs)
  should live in the module that consumes it, not in a sibling
  module that happens to have been the first one to need it. The
  same mistake would recur if e.g. a future "media keys" feature
  declared a polkit rule that other modules depend on.
