# 2026-04-29 — Idle / lock fix + concurrent biometric+password unlock

## Goal

Fix three issues reported after the auth-straightening session
(`2026-04-28-auth-straightening.md`):

1. **Random screen locks while typing / actively working.** The lockscreen
   would appear at irregular intervals even when the user was clearly
   present, then a few minutes later the system would suspend.
2. **Lockscreen UX**: on lock, the user wanted to start typing a password
   immediately (no extra Enter to "wake" the prompt), and the lockscreen
   should advertise *all* available auth methods (password, face,
   fingerprint).
3. **Concurrent unlock**: face / fingerprint should run in parallel with
   the typed password. With the post-`ff22f5a` PAM ordering
   (`unix(sufficient) → howdy → fprintd → deny`), a single PamContext
   serializes them — pam_unix immediately asks for a password and
   biometrics never run until that fails through.

## Context

Continues from `2026-04-28-auth-straightening.md` (`ff22f5a`). That session
fixed PAM ordering for `login`/`sudo`/`ly`/`bitwarden` (password first,
biometrics as fallback) and added IR-camera autodetect + hyprpolkitagent.
Auth on those services now works correctly.

The remaining problems are downstream of two unrelated upstream bugs and a
single-PamContext design limitation in our lockscreen.

## Investigation

### Bug 1: random locks — niri smithay `ext_idle_notifier_v1` regression

`stasis dump` consistently showed locks firing at exactly 600 s after
session start: `debounce_seconds(300) + lock_screen.timeout(300) = 600`.
Stasis was doing exactly what it was told — *the upstream Idle/Resumed
signal was wrong*.

Root cause: niri **v25.08** (the upstream `niri-stable` pin in
`niri-flake`) bundles a smithay revision with a broken
`ext-idle-notify-v1` implementation. Once any Idled event fires, no
matching Resumed event is sent, so stasis treats the user as permanently
idle from that point on. Issue: <https://github.com/niri-wm/niri/issues/3136>
(closed Feb 2026, labeled `not niri:smithay`). Fixed in niri ≥ v25.11; we
adopt v26.04 (Apr 2026).

Previous mitigation in commit `e6d11e3` (raised `debounce_seconds` 60 →
300) only masked the symptom — it delayed the wrong-idle trigger but did
not stop it.

### niri-flake quirk: `niri-stable` vs `niri-unstable` slots

`niri-flake` has *two* hardcoded inputs (`niri-stable.url = github:.../v25.08`
and `niri-unstable.url = github:.../main`) and builds them with different
post-install logic:

| slot           | `replace-service-with-usr-bin` | expects systemd unit form |
|----------------|--------------------------------|---------------------------|
| `niri-stable`  | `true`                         | `ExecStart=/usr/bin/niri` |
| `niri-unstable`| `false`                        | `ExecStart=niri`          |

niri v26.04 uses the new `ExecStart=niri` form. First attempt overrode
`niri-stable` to v26.04 — build failed with `substituteStream(): pattern
/usr/bin doesn't match anything in file ... niri.service` because the
stable-slot postFixup looked for the old form.

Final fix: override `niri-unstable` to v26.04 instead, register
`niri.overlays.niri` in `modules/nixos/desktop/niri.nix`, and set
`programs.niri.package = pkgs.niri-unstable`.

### Bug 2 & 3: serial PAM in lockscreen

`Quickshell.Services.Pam.PamContext` runs the configured PAM stack
sequentially within one process. Our post-`ff22f5a` `login` stack:

```
auth sufficient pam_unix.so   try_first_pass     # 12900
auth sufficient pam_howdy.so                     # 12950
auth sufficient pam_fprintd.so                   # 13000
auth required   pam_deny.so                      # 13100
```

…blocks on pam_unix asking for a password. Biometric modules only run if
pam_unix returns ignore (no password supplied) or failure. There is no way
to get howdy + fprintd to scan **at the same time** as the user typing —
unless we run two PAM stacks in two PamContexts.

## Design decisions

### Two single-purpose PAM services

Added two new entries in `security.pam.services`:

- **`quickshell-password`**: `pam_unix(required)` + `pam_gnome_keyring`.
  Password-only; never invokes biometric modules. `required` (not
  `sufficient`) so a wrong password fails fast and surfaces a
  `PamResult.Failed` to the QML side.
- **`quickshell-biometric`**: `pam_howdy(sufficient)` →
  `pam_fprintd(sufficient)` → `pam_deny(required)`. Biometric-only; never
  sets `responseRequired` because there is no password module.

Defined with raw `text =` (full pam.d file content) rather than
`security.pam.services.<name>.rules` so we get exactly the stack we want
without any framework-injected modules. PAM module names resolve via
`/run/current-system/sw/lib/security/` — verified at runtime.

### Two parallel `PamContext` instances

`LockContext.qml` now owns `pamPassword` and `pamBiometric`. Both are
started by `startAuth()`. Whichever one returns `PamResult.Success` first
calls `abort()` on the other and emits `unlocked()`. Failure handling is
asymmetric:

- Password failure: show "authentication failed", clear input buffer,
  restart `pamPassword` after 1.5 s.
- Biometric failure: silently restart `pamBiometric` after 3.0 s (don't
  spam the IR sensor or pollute the password-error UX with biometric
  noise).

### Always-shown password input + idempotent lock

`LockScreen.qml` now:

- **Idempotent `lock()`**: early-return if `locker.locked` is already
  `true`. Stops a re-trigger from stasis (or a duplicate keybind press)
  from aborting an in-flight biometric scan and clearing the password
  buffer.
- **Single `teardown()`**: every "leave lockscreen" path goes through one
  function that aborts both PamContexts, clears state, sets
  `locker.locked = false`, and runs `stasis resume`. This makes the
  pause/resume of stasis symmetric — we can no longer leave the daemon
  paused after a partial dismissal.
- **Always-shown TextInput**: `focus: true`, no `visible:` gate. The user
  can type the moment the lock surface paints.
- **Methods hint**: status text reads "password, face, or fingerprint" (or
  whichever subset is enabled). Availability is sourced from
  `QUICKSHELL_LOCK_FACE` and `QUICKSHELL_LOCK_FINGERPRINT` env vars set by
  the quickshell home module from `variables.biometrics.enable`. (Plain
  env vars rather than QML imports because the QML files are deployed
  verbatim; passing flags through Nix string interpolation would break the
  "QML stays editable" property of the module.)

### Stasis debounce restored to 60 s

With the niri bug fixed, the `e6d11e3` mitigation is unnecessary.
`debounce_seconds = 60` is plenty to absorb brief input gaps from polling
keyboards and short cross-app focus shuffles, while letting genuine idle
periods trigger the lock at the configured `lockAfter`.

## Files changed

- `flake.nix` — `inputs.niri.inputs.niri-unstable.url =
  github:YaLTeR/niri/v26.04`. Comment block explains why `niri-unstable`
  (not `niri-stable`) and links to issue #3136.
- `flake.lock` — niri-flake bumped to 2026-04-29; `niri-unstable` pinned
  to `8ed0da4` (v26.04, 2026-04-25); `niri-stable` unchanged at v25.08.
- `modules/nixos/desktop/niri.nix` — added `nixpkgs.overlays = [
  inputs.niri.overlays.niri ]` and `programs.niri.package =
  pkgs.niri-unstable`.
- `modules/nixos/biometrics.nix` — added `quickshell-password` and
  `quickshell-biometric` PAM services next to the existing `bitwarden`
  entry, both using raw `text =` stacks. Module references are absolute
  store paths (`${pkgs.howdy}/lib/security/pam_howdy.so` etc.) — see
  "Post-deploy fix" below.
- `modules/home/desktop/quickshell/default.nix` — set
  `QUICKSHELL_LOCK_FACE` / `QUICKSHELL_LOCK_FINGERPRINT` from
  `variables.biometrics.enable`.
- `modules/home/desktop/quickshell/qml/lock/LockContext.qml` — replaced
  single PamContext with `pamPassword` (`config:
  "quickshell-password"`) and `pamBiometric` (`config:
  "quickshell-biometric"`). Added `abortAuth()`, separate restart timers,
  aggregated read-only properties for the screen.
- `modules/home/desktop/quickshell/qml/lock/LockScreen.qml` — idempotent
  `lock()`, single `teardown()` for symmetric stasis pause/resume,
  always-shown focused password input, status hint built from
  availability flags.
- `modules/home/desktop/idle.nix` — `debounce_seconds = 300 → 60`,
  comment rewritten to explain the niri bug + fix.

## Verification

- `nix fmt` — clean.
- `nix flake check` — all checks passed.
- `nix build .#nixosConfigurations.laptop.config.system.build.toplevel
  --no-link` — succeeds (rebuilds niri v26.04 from source, ~4 min on
  this machine).
- `nix build '.#homeConfigurations."p@laptop".activationPackage' --no-link`
  — succeeds.
- `nix eval --raw .#nixosConfigurations.laptop.config.security.pam.services.quickshell-password.text`
  shows the expected `pam_unix(required) + pam_gnome_keyring` stack.
- `nix eval --raw
  .#nixosConfigurations.laptop.config.security.pam.services.quickshell-biometric.text`
  shows `pam_howdy(sufficient) → pam_fprintd(sufficient) →
  pam_deny(required)`.
- `ls /run/current-system/sw/lib/security/` confirms `pam_howdy.so`,
  `pam_fprintd.so`, `pam_unix.so`, `pam_deny.so`, `pam_gnome_keyring.so`
  all resolve unqualified.

## Deploy

- System: `sudo nixos-rebuild switch --flake .#laptop`
- User: `home-manager switch --flake .#"p@laptop"`
- **Reboot required** for the niri compositor upgrade to take effect.
  Until then, the user is running niri v25.08 — the broken idle behavior
  persists, but the new debounce (60 s) means the bug will trigger faster
  if the user delays the reboot. As an interim, run `stasis resume`
  manually if the screen locks at random.

## Follow-ups

- Once we have run a few uptime cycles on niri v26.04 with no spurious
  locks, consider lowering `lockAfter` from 300 s back to a more
  reasonable value (e.g. 600 s = 10 min) — the high value was set during
  the buggy era to give "more typing time" before the broken idle fired.
- The `inhibit_apps = ["mpv", "vlc", "chromium"]` list in idle.nix only
  prevents idle while those apps have focus. If we ever want
  inhibit-while-fullscreen for editors / terminals, that needs niri itself
  to expose a fullscreen-app idle-inhibit signal.
- If `niri-unstable` ever regresses in a way that affects us, downgrade by
  removing the override on `inputs.niri.inputs.niri-unstable.url` and
  swapping `programs.niri.package = pkgs.niri-stable` until upstream is
  fixed.

## Post-deploy fix: PAM dlopen failure

After deploying the initial version, biometrics still didn't trigger at
the lockscreen. `journalctl --user` revealed:

```
quickshell[20343]: PAM unable to dlopen(/nix/store/.../linux-pam-1.7.1/lib/security/pam_howdy.so):
                   ... cannot open shared object file: No such file or directory
quickshell[20343]: PAM adding faulty module: ...pam_howdy.so
```

Root cause: PAM resolves bare module names (`pam_howdy.so`) by appending
them to linux-pam's *own* `lib/security/` directory at the path linux-pam
was built into. That directory only contains the modules linux-pam itself
ships (pam_unix, pam_deny, pam_env, …). Modules from other packages
(howdy, fprintd, gnome-keyring, etc.) live in their own store paths and
are aggregated into `/run/current-system/sw/lib/security/` via NixOS's
`environment.pathsToLink`, but **PAM does not consult that path** —
`environment.pathsToLink` only feeds the user's `$PATH` and the system
profile, not PAM's internal module lookup.

NixOS's framework-managed PAM services (login, sudo, ly, the rules-style
entries above) avoid this footgun because the framework auto-prefixes
each `rules.auth.<name>.module` with the right store path. Raw `text =`
services bypass that prefixing entirely, so the burden of supplying
absolute paths falls on us.

Fix: rewrite the `quickshell-password` / `quickshell-biometric` rules to
reference modules by absolute path:

```nix
auth      sufficient  ${pkgs.howdy}/lib/security/pam_howdy.so
auth      sufficient  ${pkgs.fprintd}/lib/security/pam_fprintd.so
auth      optional    ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so use_authtok
```

`pam_unix.so` and `pam_deny.so` are left bare because they ship with
linux-pam and resolve at the default path.

Verified the resolved stacks contain absolute paths via `nix eval --raw
.#nixosConfigurations.laptop.config.security.pam.services.quickshell-{password,biometric}.text`.

Lesson for future raw-`text =` PAM services: any module that isn't part
of `linux-pam` itself needs an absolute store path. The list of "ships
with linux-pam" modules is roughly: pam_access, pam_canonicalize_user,
pam_debug, pam_deny, pam_echo, pam_env, pam_exec, pam_faildelay,
pam_faillock, pam_filter, pam_ftp, pam_group, pam_issue, pam_keyinit,
pam_lastlog, pam_limits, pam_listfile, pam_localuser, pam_loginuid,
pam_mail, pam_mkhomedir, pam_motd, pam_namespace, pam_nologin, pam_permit,
pam_pwhistory, pam_rhosts, pam_rootok, pam_securetty, pam_selinux,
pam_sepermit, pam_setquota, pam_shells, pam_stress, pam_succeed_if,
pam_time, pam_timestamp, pam_tty_audit, pam_umask, pam_unix, pam_userdb,
pam_warn, pam_wheel, pam_xauth.

## Update: niri v26.04 did NOT fix the idle bug — replacing stasis with `idled`

After deploying niri v26.04 the random locks continued. Re-investigation
on the live system showed the diagnosis above (issue #3136 = fix in
v26.04) was wrong:

- niri #3136 was closed with label `not niri:smithay`, i.e. *upstream
  redirect, not a fix*. The real bug is
  <https://github.com/Smithay/smithay/issues/1892> ("Idle notify: not
  receiving any resumed events"), still **open** as of 2026-04, no commits
  since 2025-12-29.
- niri v26.04 release notes mention only one idle-related change
  ("compounding slowdown over time when using a high Hz mouse"), which is
  a different bug.
- Live verification: `stasis info` showed a monotonically decrementing
  `Next: LockScreen in N s` countdown that did **not** reset on keystrokes
  or pointer movement. `stasis dump` showed locks firing at irregular
  intervals matching "saw Idled, never saw Resumed".

Inspection of the stasis 1.1.0 binary
(`/nix/store/.../stasis`) via `strings`/`rg` showed it relies entirely on
`ext_idle_notifier_v1` (`get_idle_notification` and
`get_input_idle_notification`). It does bind `wl_pointer` and
`wl_keyboard` for session handles but does not consume their events to
reset the idle counter, and it has no `/dev/input` or libinput backend
compiled in. Every wayland-protocol idle daemon (swayidle, hypridle,
cosmic-idle, wayidle) inherits the same smithay layer on niri and would
hit the same bug.

### Decision: write a small daemon that reads `/dev/input/event*` directly

systemd-logind exposes `IdleAction` but its docs are explicit: "this
requires that user sessions correctly report the idle status to the
system." Logind itself does not track input — it relies on session
clients calling `org.freedesktop.login1.Session.SetIdleHint()`. So
"switch the source to logind" still requires us to feed IdleHint from
*something*, and the only input source that bypasses the smithay bug is
the kernel input layer.

`packages/idled/` is a ~330-line Rust daemon that:

- Opens every `/dev/input/event*` device whose evdev capabilities mark it
  as a keyboard / pointer / touchpad (skips lid switch, power button).
- Watches `/dev/input/` via `inotify` for hot-plug (USB keyboard,
  bluetooth mouse) and attaches new devices live.
- Maintains `last_input` from any input event and runs a 1 Hz tick that
  fires per-stage shell commands when `now - last_input >= timeout`.
- Tracks per-stage `fired` flags so a stage doesn't re-fire until input
  resets it. On input after fire, runs the stage's optional
  `resume_command` (used by DPMS to wake monitors immediately).
- Listens to logind `PrepareForSleep(false)` to treat resume as fresh
  input (avoids re-locking using elapsed-since-pre-suspend time).
- Listens to logind `BlockInhibited` and defers all stages while any
  client holds an `idle` inhibit (so video players, calls, etc., still
  block idle the same way they did with stasis).

Permissions: runs as the user (not root) so the `command` strings inherit
`WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` and can call `quickshell ipc call
lock lock`, `niri msg action power-off-monitors`, `systemctl suspend`
without environment juggling. This requires the user be in the `input`
group; added in `hosts/laptop/configuration.nix`. The trade-off is that
any user-mode process can read keystrokes from `/dev/input` — acceptable
for a single-user laptop. A future revision could split into a privileged
input reader and an unprivileged scheduler if multi-user use becomes
relevant.

Build + packaging:

- Cargo dependencies: `evdev`, `inotify`, `tokio`, `zbus`, `serde`,
  `toml`, `clap`, `tracing`, `anyhow`, `futures-util`. All in nixpkgs;
  no additional flake input.
- `packages/idled/default.nix` builds via `rustPlatform.buildRustPackage`
  with `cargoLock.lockFile = ./Cargo.lock`.
- `overlays/idled.nix` exposes it as `pkgs.idled` for both the NixOS and
  home-manager pkgs instances. Retirement condition: smithay #1892 fixed
  AND niri picks up the fix.
- `modules/home/desktop/idle.nix` rewritten to install `idled`, write
  `~/.config/idled/config.toml` from `variables.idle.{lockAfter,
  dpmsAfter, suspendAfter}`, and run `idled` as a `WantedBy=
  graphical-session.target` user systemd service with sensible hardening
  (`ProtectSystem=strict`, `ProtectKernelTunables`, etc., but **not**
  `PrivateDevices=true` — that would mask `/dev/input`).
- `modules/nixos/desktop/niri.nix` no longer installs `stasis` in
  `environment.systemPackages`.

Verification:

- `nix build .#nixosConfigurations.laptop.config.system.build.toplevel
  --no-link` succeeds.
- `nix build .#homeConfigurations."p@laptop".activationPackage --no-link`
  succeeds; the resulting tree contains `.config/idled/config.toml` and
  `.config/systemd/user/{idled.service,graphical-session.target.wants/idled.service}`.
- Smoke test: running the freshly-built `idled` against the deployed
  config shows it parses the three stages (`lock`/`dpms`/`suspend`),
  connects to logind dbus successfully, reads `BlockInhibited` (current
  value: `handle-power-key`, no `idle`), and attempts to open every
  `/dev/input/event*`. Failures with `EACCES` are expected pre-deploy
  because the user isn't yet in the `input` group; will resolve after
  `nixos-rebuild switch` + re-login.

Deploy steps:

1. `sudo nixos-rebuild switch --flake .#laptop` (adds user to `input`
   group; removes stasis from systemPackages).
2. **Log out + log back in** (or reboot) to pick up the new group
   membership. Without this, `idled` still gets EACCES on every event
   device.
3. `home-manager switch --flake .#"p@laptop"` (installs `idled.service`
   user unit and config; replaces the old stasis spawn-at-startup).
4. `systemctl --user start idled` (or `systemctl --user restart idled`
   if HM didn't restart it on activation).
5. Verify with `journalctl --user -u idled -f` — should see
   "watching input device" lines for keyboard, touchpad, etc.

Files added:

- `packages/idled/Cargo.toml`
- `packages/idled/Cargo.lock`
- `packages/idled/default.nix`
- `packages/idled/src/main.rs`
- `packages/idled/src/dbus.rs`
- `packages/idled/src/input.rs`
- `overlays/idled.nix`

Files modified:

- `overlays/default.nix` — register the new overlay.
- `modules/home/desktop/idle.nix` — rewritten to drive `idled` instead of
  stasis (config.toml + systemd user unit; no more
  `programs.niri.settings.spawn-at-startup` for stasis).
- `modules/nixos/desktop/niri.nix` — drop `stasis` from `systemPackages`.
- `hosts/laptop/configuration.nix` — add `input` to `extraGroups`.

What this does NOT change:

- The lockscreen UI (`quickshell` lock + concurrent face/fingerprint/
  password) is untouched and still works exactly as in the prior section.
- The PAM stacks (`quickshell-password` / `quickshell-biometric`) are
  untouched.
- niri pin is unchanged (still v26.04, just for completeness — even
  though it doesn't fix the idle bug, no reason to roll back).

## Update 2: revert the niri v26.04 override — it was based on a wrong diagnosis

After deploying `idled` and confirming via `journalctl --user -u idled`
that input devices were being watched and the random-lock bug was gone,
we revisited the niri pin. The original justification for overriding
`niri-unstable` to v26.04 was the assumption that v26.04 fixed the
smithay `ext_idle_notifier_v1` Resumed-event bug. That assumption was
wrong (see Update 1 above): the bug is upstream Smithay #1892, still
open, and was never addressed in any niri release.

With `idled` reading `/dev/input/event*` directly, the wayland idle
protocol is no longer in our path. The niri version has no influence on
auto-lock behavior. So the v26.04 pin now provides zero benefit and
carries real costs:

- A custom flake input override that has to be remembered and re-checked
  on every niri-flake bump.
- niri builds from source on every bump (~4 min on this machine) instead
  of using the substituter cache for the upstream `niri-stable` pin.
- The `niri-unstable` slot is by definition less tested than
  `niri-stable`; niri-flake's stable slot exists specifically to hold
  back potentially regressing revisions.
- The "use niri-unstable not niri-stable because of
  `replace-service-with-usr-bin = true`" footgun explainer in
  `flake.nix` was pure cruft once the underlying motivation evaporated.

Reverted:

- `flake.nix` — removed the `inputs.niri.inputs.niri-unstable.url` line
  and the comment block. niri input is back to the bare
  `github:sodiboo/niri-flake` form.
- `modules/nixos/desktop/niri.nix` — removed both `nixpkgs.overlays = [
  inputs.niri.overlays.niri ]` and `programs.niri.package =
  pkgs.niri-unstable`. The niri NixOS module now installs whatever
  niri-flake's `programs.niri` module installs by default
  (`niri-stable`).
- `flake.lock` — `nix flake update niri` repinned niri-flake to a fresh
  commit and dropped the v26.04 override on niri-unstable.

Verified: `nix eval --raw
.#nixosConfigurations.laptop.config.programs.niri.package.name` reports
`niri-25.08`. `nix build` of system + home + `nix flake check` all
succeed.

Lesson: don't pin to a newer upstream version "just to be safe" when the
actual fix is in our own code. The override paid maintenance interest
forever for a benefit that never existed.

Files modified by this revert (on top of all changes listed above):

- `flake.nix` — removed override + comment block.
- `flake.lock` — niri repinned without override.
- `modules/nixos/desktop/niri.nix` — removed overlay registration and
  package selection lines.

## Update 3: face-first PAM ordering for sudo / login / ly

Continuing the same session. With idle-detection fixed and the niri
override gone, the user asked to flip `sudo` (and login / ly) to
face-first ordering — match a Windows Hello "look-and-go" UX rather than
"type-and-fall-through-to-biometrics".

`bitwarden` keeps password-first because vault unlock is a deliberate
gesture and we want a typed password rather than glancing at the screen
to open the vault.

### What changed in `modules/nixos/biometrics.nix`

The single `reorder` builder was generalised to `mkReorder { howdyOrder
}`, and three policies are applied per service:

| service     | policy           | resolved auth order                                         |
|-------------|------------------|-------------------------------------------------------------|
| `sudo`      | face-first       | howdy(11500) → unix(11700) → fprintd(13000) → deny(13100)   |
| `login`     | face-first       | unix-early(11700) → keyring(12200) → howdy(12500) → unix(12900) → fprintd(13000) → deny(13100) |
| `ly`        | face-first       | (same as login)                                             |
| `bitwarden` | password-first   | unix(11700) → howdy(12950) → fprintd(13000) → deny(13100)   |

Verified by `nix eval --raw .#nixosConfigurations.laptop.config.security.pam.services.<svc>.text`.

Two distinct howdy slot positions were necessary:

- **sudo** has no `pam_unix-early` and no `pam_gnome_keyring` in its
  stack, so howdy can sit at the very top (11500, just below
  `pam_unix-account` at 11000 and below the `auth pam_unix` at 11700).
- **login / ly** have `pam_unix-early(optional, order 11700)` and
  `pam_gnome_keyring(optional, order 12200)`. Putting howdy *above* those
  would skip the AUTHTOK capture and the keyring would never get a chance
  even if a password were typed. Howdy is therefore slotted at 12500 —
  *below* keyring(12200) and *above* the deciding `pam_unix(sufficient,
  12900)` — so the chain is:
  1. unix-early(11700) tries to capture AUTHTOK from any password input.
  2. gnome_keyring(12200) consumes AUTHTOK if present and unlocks the
     login keyring.
  3. howdy(12500) attempts face match; on success short-circuits the
     stack.
  4. unix(12900) prompts for password as fallback.
  5. fprintd(13000) prompts for finger as final fallback.

### Known caveats / footguns

1. **Keyring regression on face-login.** When howdy succeeds at step 3
   on login or ly, no password is ever typed, so AUTHTOK is empty and
   pam_gnome_keyring at step 2 had nothing to consume. The login keyring
   stays locked; the user will see a separate "unlock keyring" prompt
   later when an app (Chrome password store, secrets daemon, etc.) needs
   it. This is the intentional tradeoff for face-first login. Workaround
   for sessions where the keyring is needed: type the password into ly /
   login instead of looking at the camera.

2. **Every `sudo` invocation now triggers the IR camera.** With howdy
   first and `sufficient`, PAM blocks on howdy until it returns
   (success or timeout, default 4s) before falling through to the password
   prompt. Consequences:
     - On a successful face match: `sudo` returns near-instantly. Big
       UX win.
     - On no-face / occlusion / bad lighting: ~4s pause before the
       `Password:` prompt appears.
     - `try_first_pass` does *not* help here because no module above
       howdy populates AUTHTOK on sudo (unlike login/ly). Anything the
       user pre-types into the terminal is buffered by the TTY but not
       seen by PAM until howdy yields.
   To dial back the wait, lower howdy's timeout (`/etc/howdy/config.ini`
   `[video] max_height` and `[core] timeout`); managed via
   `services.howdy.settings`. Currently default 4s — acceptable for now;
   revisit if it gets annoying.

3. **`sudo -n` (non-interactive)** behaves the same as before: PAM
   honours the `nopasswd` ticket, doesn't run howdy at all, returns
   immediately. Verified mentally from the stack — howdy is `sufficient`
   not `required`, and `sudo -n` never enters interactive auth.

4. **Lockscreen unaffected.** `quickshell-password` and
   `quickshell-biometric` are independent raw-text PAM services running
   in two parallel PamContexts. The face-first reorder only touches
   `rules.auth.<name>.order` on the framework-managed services
   (sudo/login/ly/bitwarden) and doesn't change anything about the
   lockscreen path.

### Verification

- `nix build .#nixosConfigurations.laptop.config.system.build.toplevel
  --no-link` succeeds.
- `nix flake check`: all checks pass.
- `nix fmt`: clean.
- Resolved PAM stacks for sudo/login/ly/bitwarden inspected via
  `nix eval --raw` and match the table above.

### Files modified by this update

- `modules/nixos/biometrics.nix` — replaced `reorder` with
  `mkReorder { howdyOrder }` builder and three named policies; updated
  the comment block to document the face-first / password-first split
  and the keyring caveat.
