# 2026-04-28 — Phase 2 cleanup

## Goal

Second pass of the code-review cleanup. Where Phase 1 deleted dead code and
fixed obvious bugs, Phase 2 tackles the structural rough edges: hard-coded
paths, polling loops vs event subscriptions, schema drift between hosts,
and the half-finished WSL scaffolder.

## Context

Continues from `2026-04-28-phase1-cleanup.md`. After Phase 1 the bar/lock/idle
stack ran clean and three orphan files were gone. Phase 2 picks up the
remaining items from the review's P1 + a few P2-grade ones that were cheap
to roll in while touching adjacent files.

## Changes

### 1. `LockScreen.qml` — wallpaper path parametrized

Replaced the hard-coded `file:///home/p/.wallpaper/current.jpg` with a
`Quickshell.env("HOME")`-derived path resolved at runtime. The lock screen
now works for any user without a config edit. `wallpaper.nix` always emits
the `current.jpg` symlink so the path is stable across hosts.

### 2. `VolumeOsd.qml` — IPC removed, event-driven via Pipewire singleton

Quickshell ships a native `Quickshell.Services.Pipewire` singleton with
`defaultAudioSink.audio.{volume,muted}` properties and matching change
signals. Replaced the IPC-driven OSD with a `PwObjectTracker` +
`Connections` block that fires the popup whenever the default sink's
volume or mute state changes — regardless of whether the change came from
niri keybinds, the UI flyout, or a third-party app like pavucontrol.

A 1.5 s startup grace period (`armed`) suppresses the OSD on initial bind
so the popup doesn't flash on every shell restart.

niri keybinds were not changed: they still call `wpctl set-volume` /
`wpctl set-mute` and the OSD picks up the resulting PipeWire change
signal. This is strictly more general than the original IPC plan.

### 3. `flake.nix` + `flake.lock` — `nixvim` input removed

The `nixvim` input was declared but every `.nix` reference was a comment
saying "we deliberately don't use nixvim". `nix flake lock` reported the
removal of `nixvim` and four transitive inputs (flake-parts, two
nixpkgs-lib siblings, systems). No functional change.

### 4. `modules/home/shell/zsh.nix` — duplicate direnv block dropped

`programs.direnv` was declared in both `direnv.nix` and `zsh.nix`. The
zsh.nix block was redundant (the standalone module already enables
`enableZshIntegration`). Kept `direnv.nix` as the single source.

### 5. All `variables.nix` files — stale "swayidle" comments updated

Idle is now driven by `stasis` (per `2026-04-26-quickshell-idle-daemon.md`).
The comment "Applied by modules/home/desktop/idle.nix via swayidle under
the user's session" survived in laptop, wsl, wsl-arm, and _template
variables.nix. Replaced "swayidle" → "stasis" in all four.

Session logs were left untouched per AGENTS.md ("Do not edit past session
files").

### 6. WSL host explicit posture + `new-host.nix --wsl` overhaul

Both WSL hosts now carry explicit `false` overrides for keys that don't
make sense on WSL:

- `hosts/wsl/variables.nix`: `hardwareHacking.enable = true → false`.
- `hosts/wsl-arm/variables.nix`: added `hardwareHacking.enable = false`
  (was previously relying on `or false` defaulting in the gating modules).

`apps/new-host.nix` updated:

- Dropped the dead first-attempt sed block (the one with the literal
  `\n` pattern that the comment itself flagged as "best-effort across
  platforms"). The authoritative range-scoped seds that follow it
  remain.
- Added explicit `--wsl` overrides for `audio.easyeffects.enable`,
  `apps.vscode.enable`, and `hardwareHacking.enable`. These match the
  posture of the existing WSL hosts.
- Indentation normalised in the patch block.

`hosts/_template/variables.nix` gained an explicit
`hardwareHacking.enable = false` so the key exists for the scaffolder's
sed to flip and is documented for new-host authors.

Verified end-to-end with `nix run .#new-host -- testwsl --wsl --user
testuser` in a tmpdir; the generated host has every expected key set
correctly and contains no `CHANGEME` references except in the git
identity (which is intentional; user fills it in via $EDITOR).

### 7. `wallpaper.nix` default + template path cleanup

The wallpaper module's default directory was `"%h/.wallpaper"` —
systemd-unit syntax that would have been written into the shell script
literally, creating a directory called `%h`. Changed the default to
`"${config.home.homeDirectory}/.wallpaper"` so it always resolves to the
right user's `$HOME` at home-manager build time.

Removed the explicit `directory = "/home/p/.wallpaper"` from
`hosts/laptop/variables.nix` (it was identical to the new default), and
removed `directory = "/home/CHANGEME/.wallpaper"` from
`hosts/_template/variables.nix` (the broken `CHANGEME` literal that
new-host.nix wasn't substituting). The template comment now points
users at the default explicitly.

## Verification

```sh
nix flake check                                                                         # passes
nix build .#nixosConfigurations.laptop.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.wsl.config.system.build.toplevel --no-link
nix build .#homeConfigurations."p@laptop".activationPackage --no-link
nix fmt                                                                                 # no diff
EDITOR=true nix run .#new-host -- testwsl --wsl --user testuser                         # in tmpdir
```

All builds succeed. Pre-existing warnings (unknown `mylib` flake output,
missing `meta` on apps) are unchanged. No `switch` performed.

`nix flake check` time dropped slightly with `nixvim` gone.

## Lessons

1. **Quickshell ships rich native bindings** (`Pipewire`, `UPower`,
   `Bluetooth`, `Mpris`, `SystemTray`, `Greetd`, `Pam`, `Notifications`)
   that the codebase has been ignoring in favour of polling subprocesses
   via `Process` + `Timer`. Phase 3 should sweep these in the bar
   widgets as well — `Volume.qml` and `Brightness.qml` (still polling
   at 50 ms) are the obvious next victims.
2. **`PwObjectTracker` is required** to keep the audio sub-object alive
   when subscribing to its change signals through a path like
   `Pipewire.defaultAudioSink.audio`. Without the tracker, the audio
   wrapper can be garbage-collected mid-binding.
3. **The flake-only-sees-tracked-files rule applies only to *new* files,
   not to edits.** Confirmed during Phase 1; unchanged here. `git add` is
   still recommended habit before any build.
4. **`nix run .#new-host` will hang on `$EDITOR` in non-interactive
   environments**. Run with `EDITOR=true` for scripted testing.
5. **The new-host scaffolder's sed-based fixups are still fragile** in
   principle — they depend on the template's exact phrasing — but the
   recent overhaul plus the test harness above makes regressions easy
   to catch. A future Phase 3 item could replace the seds with a
   templating step (`pkgs.writeText` + parameter substitution).

## Next

Phase 3 (deferred indefinitely; per user direction):

- Bar widget polling → event subscriptions (`Volume`, `Brightness` via
  Pipewire/`UPower` bindings; `Workspaces` and `ActiveWindow` via
  `niri msg event-stream`).
- `Bar.qml` chip-position math via `mapToItem` instead of manual
  `parent.x` chains.
- Drop the misleading `module Theme` line from
  `modules/home/desktop/quickshell/qml/qmldir`.
- Reconcile `audio/pipewire.nix:18` comment vs value (150% claim, 1.0 in
  code).
- Modernize `biometrics.nix` polkit rules (deprecated localauthority →
  rules.d JS).
- Move `github-copilot-cli` and `opencode` from system to home-manager.
- Decide fate of empty `pkgs/default.nix` stub.
- Consider replacing the new-host sed harness with a template-substitution
  step.
