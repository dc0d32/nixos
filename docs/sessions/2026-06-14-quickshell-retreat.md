# Quickshell retreat — waybar + mako + fuzzel + cliphist + swaylock-effects

**Date:** 2026-06-14
**Commit:** `8b67b4a` (on top of `a8f9963` + `4d43452`, not yet pushed)
**Net diff:** 72 files changed, +483 / −5275 (−4792 lines)

## Context

After the YOLO cleanup (`a8f9963`) gutted the egghead installer and
the home-grown impermanence/restore tooling in favor of
`nixos-anywhere` + a tiny `scripts/init-backup.sh` + a runbook, the
operator asked for an honest assessment of the niri + Quickshell
setup.

The Quickshell setup was:

- ~4850 LOC of QML across ~30 files under `flake-modules/quickshell/qml/`
  (bar, lockscreen, OSDs, notifications, flyout panes, launcher,
  clipboard picker, screenshot picker, plus per-feature state
  singletons).
- One module file (`flake-modules/quickshell.nix`, 109 lines)
  wiring the binary, the QML deployment via `xdg.configFile`, and
  `security.pam.services.quickshell-biometric` for the lockscreen.
- A single solo-maintained framework still pre-1.0, sitting on
  the critical path for screen unlock.

Honest take delivered in three tiers (cheap risk reduction / lock
only / honest retreat). Operator chose the honest retreat.

## Decisions

1. **Module layout: split, not combined.**
   - `flake-modules/lockscreen.nix` — cross-class. NixOS side
     contributes `security.pam.services.swaylock { fprintAuth =
     true; }`; HM side installs `swaylock-effects` and writes
     `~/.config/swaylock/config`.
   - `flake-modules/desktop-shell.nix` — HM-only. Bundles waybar,
     mako, fuzzel, cliphist text + image watchers, and the
     `screenshot` / `clipboard-pick` `writeShellApplication`
     wrappers.

   Rationale: the lockscreen has system-side PAM dependencies the
   bar/launcher do not; it's also the piece that's safety-critical
   (a broken lockscreen locks you out at 2 AM). Keeping it in its
   own file makes it easy to swap out independently if
   swaylock-effects ever bit-rots.

2. **Native niri IPC consumer in waybar.** Waybar 0.15.0 ships
   `niri/workspaces` and `niri/window` modules out of the box, so
   the bar talks to niri directly instead of through a custom
   adapter. Verified at runtime ("Niri IPC starting" + bar shows
   workspace pills).

3. **Keybinds preserved.** Existing Super+Space (launcher),
   Super+Alt+L (lock), Print / Shift+Print (screenshot),
   Mod+Shift+C (clipboard picker) all keep their bindings. Just
   the spawn targets change (fuzzel / swaylock /
   `screenshot region` / `clipboard-pick`).

4. **No face unlock on the screen lock.** howdy + swaylock isn't
   a combination anyone has wired up. Lock falls back to password
   + fingerprint via fprintd. Face unlock still works for
   sudo/login/ly via the existing PAM reordering in
   `biometrics.nix`. Trade accepted.

5. **`biometrics.enable` signal option retained.** Even with no
   current consumer (the quickshell lockscreen was the last one),
   the option is kept so a future cross-module signal can publish
   "this host has biometrics" without re-introducing the
   convention boilerplate.

6. **No QML state-singleton replacements.** Quickshell's
   `BatteryState`, `BluetoothState`, `NetworkState`,
   `VolumeState`, `BrightnessState`, `WeatherModel`, etc. were
   the QML-side cached projections of UPower / NetworkManager /
   PipeWire / brightnessctl state. Their replacement is the
   waybar module that talks to the same source directly — no
   intermediate cache. Less code, one fewer translation layer.

## Files

**New:**
- `flake-modules/lockscreen.nix` (~80 lines)
- `flake-modules/desktop-shell.nix` (~260 lines)

**Deleted:**
- `flake-modules/quickshell.nix` (109 lines)
- `flake-modules/quickshell/qml/` — entire tree (~30 files /
  ~4850 LOC)

**Modified:**
- `flake-modules/niri.nix` — keybind targets, dropped
  quickshell-flyout blur exclusion (kept catch-all blur)
- `flake-modules/idle.nix` — `lockCmd → swaylock-effects`
- `flake-modules/biometrics.nix` — dropped
  `quickshell-biometric` PAM stanza; doc-comments updated
- `flake-modules/bundles/{home-desktop,home-kid}.nix` — swap
  `quickshell` → `desktop-shell` + `lockscreen`
- `flake-modules/hosts/{pb-x1,pb-t480,m-pc}.nix` —
  `nixos.quickshell` → `nixos.lockscreen`
- `flake-modules/kid-launcher.nix` — dropped `org.quickshell`
  desktop-entry hide
- Comment-only sweeps: bluetooth.nix, polkit-agent.nix,
  surface.nix, hm-auto-upgrade.nix, home-manager-bootstrap.nix,
  hosts/ah-1.nix
- `AGENTS.md` — replaced "Quickshell (QML bar/shell)" section
  with new "Desktop shell" section; cross-module-signals example
  + deploy-split example updated
- `README.md` — dropped `quickshell/qml/` from layout tree

## Validation

`NIXOS_ALLOW_PLACEHOLDER=1 nix flake check --impure` passes for
all 5 hosts (pb-x1, pb-t480, m-pc, ah-1, wsl).

Field-tested on pb-x1 mid-session:

- `home-manager switch --flake .#'p@pb-x1'` succeeded.
- waybar.service active; bar renders at eDP-1 1920x28 with
  workspaces, window title, clock, battery, network, bluetooth,
  pulseaudio, backlight, tray. Native niri IPC connection
  confirmed in the journal.
- cliphist-text.service + cliphist-image.service active;
  clipboard captures verified.
- fuzzel pops as overlay; iterated on font size with operator
  (11 → 9 → 8 → 6 → 7pt), settled at `monospace:size=7` with
  `line-height = 11`. Encoded in `desktop-shell.nix`.
- `screenshot region` → slurp picker → satty annotation window
  → discard path verified end-to-end.
- `clipboard-pick` → fuzzel dmenu over cliphist history → wl-copy
  verified end-to-end.

**Deferred to first fresh install:**

- swaylock actual unlock (UI render + password unlock + fingerprint
  unlock) — requires the system rebuild that installs
  `/etc/pam.d/swaylock`. On pb-x1 this can also happen any time
  via `sudo nixos-rebuild switch --flake .#pb-x1` followed by
  `pkill -x quickshell && systemctl --user restart idled.service`.
- mako notifications visual — quickshell still holds the
  `org.freedesktop.Notifications` D-Bus name in the running
  session, so mako can't take over until quickshell is killed.
- niri config reload — `~/.config/niri.kdl` was rewritten with
  the new keybinds, but niri's running session still has the
  old in-memory config. `niri msg action reload-config` (or a
  logout/login cycle) picks it up.

## Quirks discovered

- **Mako HM option migration.** The old top-level
  `services.mako.{defaultTimeout,borderRadius,borderColor,…}`
  options are deprecated; the new path is
  `services.mako.settings.{default-timeout,border-radius,…}` with
  kebab-case keys under `settings`. Initial HM switch ran with
  warnings; `desktop-shell.nix` was rewritten to the new form
  and re-staged.

- **Two-bars-stacked layer-shell behavior.** While the HM switch
  was active but the running quickshell process was still alive,
  both bars rendered at top of eDP-1 (wlroots layer-shell stacks
  anchored surfaces at the screen edge, doesn't replace them).
  Cosmetic only; resolves on first logout/login.

## Operator's next moves (recorded for next session)

1. **pb-t480** fresh install (currently a placeholder host).
   Boot installer ISO; from any machine with this flake run
   `./scripts/install.sh pb-t480 <ip>`. Then on first boot,
   regenerate `hosts/pb-t480/hardware-configuration.nix`,
   commit, push.
2. **pb-x1** fresh install (same flow). May seed `/persist/home/p`
   from the pb-t480 repo first via `scripts/seed-from-host.sh
   --from pb-t480 --user p` if helpful.
3. **m-pc** fresh install (same flow).

The first fresh install also field-tests the rest of the
quickshell retreat (swaylock unlock with fingerprint + password,
mako fires on a real notification, fuzzel on Super+Space through
niri's own keybind handling).

## Still deferred (from the YOLO cleanup session)

`features.<name>.enable` refactor across ~66 modules + 4 bundles
+ 5 host bridges. Captured in `plan.md` with reminder triggers.
