# 2026-04-28 — Phase 3 cleanup

## Goal

Final pass of the code-review cleanup. Phase 1 ripped out dead code; Phase 2
fixed structural rough edges (paths, polling, schema drift). Phase 3 finishes
the migration to event-driven QML, modernizes the polkit + scaffolder, and
sweeps the last orphan stub.

## Context

Continues from `2026-04-28-phase2-cleanup.md`. After Phase 2 the bar still
had four widgets polling on `Timer { interval: 50..1000 }` and one wrapped
the `niri msg event-stream` per widget. Quickshell ships native singletons
under `Quickshell.Services` (`Pipewire`, `UPower`, etc.) and a streaming
parser (`SplitParser`); both let us replace the polls with proper
subscriptions. Two unrelated items were rolled in while touching adjacent
files: a `.pkla` → `rules.d` polkit migration and the `pkgs/default.nix`
stub deletion.

## Changes

### 1. `Volume.qml` — Pipewire singleton subscription

Replaced 1 s `Timer` polling `pactl get-sink-volume @DEFAULT_SINK@` (string
parsing) with `Quickshell.Services.Pipewire.defaultAudioSink.audio.{volume,
muted}`. Wrapped the sink ref in `PwObjectTracker { objects: [defaultSink] }`
so the audio sub-object stays bound and emits `volumeChanged`/`mutedChanged`
the moment PipeWire sees the change. Volume display now updates on
keypresses, application changes, and external `pactl` invocations with no
poll.

### 2. `Brightness.qml` — udev event subscription

Replaced 50 ms `Timer` polling `brightnessctl get` with a one-shot startup
read followed by a long-running `udevadm monitor --udev
--subsystem-match=backlight` consumed via `SplitParser { splitMarker: "\n" }`.
Each `change` event re-reads the current brightness once. CPU at idle drops
from "wake every 50 ms" to "wake on keypress only", and the backlight value
is still authoritative because we re-read after the udev hint instead of
parsing it.

### 3. `Workspaces.qml` + `ActiveWindow.qml` — shared `NiriState` singleton

Both widgets previously spawned their own long-running
`niri msg --json event-stream` process and parsed the same JSON twice.
Created a new singleton `modules/home/desktop/quickshell/qml/NiriState.qml`
that owns one `Process` + `SplitParser`, dispatches the event-kind tag, and
exposes:

- `workspaces` — list of `{id, idx, output, name, is_focused, is_active,
  active_window_id}`.
- `windowsById` — `{id: window}` map keyed on niri's window id.
- `focusedWindowId` / `focusedWindow` — derived.

Registered as `singleton NiriState 1.0 NiriState.qml` in
`modules/home/desktop/quickshell/qml/qmldir`. `Workspaces.qml` reads
`NiriState.workspaces`; `ActiveWindow.qml` reads `NiriState.focusedWindow`.
Net: one event-stream per session, half the QML, no polling, and adding
new niri-aware widgets is now a one-liner.

### 4. `Bar.qml` — chip-position math via `chipCX(...)`

The eight chip-center bindings (`networkCX`, `volumeCX`, …) were unrolled
manual sums of `chip.x + chip.parent.x + chip.parent.parent.x +
chip.parent.parent.parent.x + chip.width / 2`, presumably written that way
because the author didn't trust QML's binding engine to property-capture
through a JS function call. It does — every property read inside a binding's
JS expression is captured by the engine, including reads in called
functions. Replaced the eight unrolled sums with `chipCX(chip)` calls. Same
reactivity, ¼ the lines, structure-agnostic (the function walks the parent
chain to `bar`).

### 5. `qmldir` — drop `module Theme` line

The `qmldir` started with `module Theme`, which would have made every type
a fully-qualified `Theme.Bar`, `Theme.Volume`, etc. — but everything
else in the repo imports the directory unqualified (`import "."`,
`import ".."`). The `module` line was dead and inconsistent with the rest;
removed.

### 6. `pipewire.nix` — comment fix

`channelmix.max-volume = 1.0` had a comment claiming "Allow volume up to
150% (1.5)". Updated comment to reflect the actual cap (100% / 1.0) and
noted that raising it is gated on downstream gain-staging.

### 7. `biometrics.nix` — `.pkla` → `rules.d` JS rule

The `polkit-1/localauthority/50-local.d/bitwarden-biometrics.pkla` file
plus a placeholder JS-comment-only `security.polkit.extraConfig` were
replaced with a single modern JS rule:

```js
polkit.addRule(function (action, subject) {
  if (action.id == "com.bitwarden.Bitwarden.unlock" && subject.active) {
    return polkit.Result.AUTH_SELF;
  }
});
```

Same semantics (active session → require user re-auth, which dispatches
into the `bitwarden` PAM service for biometric verification) but uses the
forward-supported `rules.d` loader. polkit is dropping the `.pkla`
loader at 0.121.

### 8. AI CLIs moved to home-manager

`github-copilot-cli` and `opencode` were sitting in
`hosts/laptop/host-packages.nix` (`environment.systemPackages`) even though
both are user-scoped (config in `$XDG_CONFIG_HOME`, auth in user keyring).
Moved both to a new `modules/home/tools/ai-cli.nix` module imported via
`modules/home/default.nix`. Distinct from `tools/gh.nix` which is
GitHub-CLI-specific and configures `programs.gh`.

### 9. `pkgs/default.nix` stub deleted

Empty stub `{ pkgs }: { }` was wired into `flake.nix` `packages` output but
never had any custom packages. Deleted both the file and the import; the
`packages` output is now `forAllSystems (_: { })`. If the repo ever needs
custom packages, they can be added back as a directory.

### 10. `apps/new-host.nix` — template substitution instead of seds

The previous scaffolder copied `hosts/_template/variables.nix`, then ran
~13 `sed -i` invocations to flip flags per flavor (`--mac` / `--wsl` /
default Linux). Each sed used a multi-line range pattern (`/^  apps = {/,
/^  };/ s|...|...|`) to avoid hitting the wrong key with the same name.
Brittle: a comment containing the same text or a key reordering would
silently break the flip; a typo in any sed would silently leave the wrong
default in place; new flags required adding a sed for each new flavor.

Replaced the entire copy-then-sed pipeline with a flavor-keyed shell case
that sets ~17 booleans + `SYSTEM` + `GPU_DRIVER`, then a single `cat
<<EOF > variables.nix` heredoc that interpolates them in order. The
`hosts/_template/variables.nix` is still read by humans browsing the repo
and copied as a fallback for the other files (`configuration.nix`,
`host-packages.nix`), but the generated `variables.nix` overwrites the
copied one. New flags now mean "add a line to the case + a line to the
heredoc" — same place, atomic.

Also dropped `gnused` and `findutils` from `runtimeInputs` (no longer
needed) and replaced the only remaining sed (drop `hardware-configuration.nix`
import line) with a `grep -v` rewrite.

Smoke-tested all three flavors (`--wsl`, `--mac`, default linux) plus the
`--mac --wsl` mutex. The generated WSL variables.nix evaluates cleanly:
`nix eval .#nixosConfigurations.<scaffolded>.config.system.build.toplevel.drvPath`
returned a real `.drv` after a stub `hardware-configuration.nix` was
written.

## Verification

- `nix flake check` → all checks passed
- `nix build .#nixosConfigurations.laptop.config.system.build.toplevel --no-link` → ok
- `nix build .#nixosConfigurations.wsl.config.system.build.toplevel --no-link` → ok
- `nix build .#homeConfigurations."p@laptop".activationPackage --no-link` → ok
- `nix fmt` → no diffs
- Scaffolder smoke tests: `--wsl`, `--mac`, default linux, `--mac --wsl`
  mutex (rejected as expected). Generated WSL config eval'd to a real
  derivation.

Not switched (per AGENTS.md, switches are a user action). The Quickshell
QML changes only take effect after `home-manager switch` + a quickshell
restart; the polkit + biometrics changes take effect after
`nixos-rebuild switch`.

## Files

Created:
- `modules/home/desktop/quickshell/qml/NiriState.qml`
- `modules/home/tools/ai-cli.nix`
- `docs/sessions/2026-04-28-phase3-cleanup.md`

Modified:
- `apps/new-host.nix`
- `flake.nix`
- `hosts/laptop/host-packages.nix`
- `modules/home/default.nix`
- `modules/home/desktop/quickshell/qml/qmldir`
- `modules/home/desktop/quickshell/qml/bar/{Bar,Volume,Brightness,Workspaces,ActiveWindow}.qml`
- `modules/nixos/audio/pipewire.nix`
- `modules/nixos/biometrics.nix`

Deleted:
- `pkgs/default.nix` (and the now-empty `pkgs/` directory)

## Follow-ups (not done this session)

- Consider exposing `NiriState.outputs` if any future widget needs the
  monitor list. Not needed by current widgets.
- The `chipCX(chip)` walk in `Bar.qml` will break if a chip is reparented
  outside the bar tree, but no chip ever is.
- `linux-enable-ir-emitter` retire-when-firmware-fixes comment in
  `biometrics.nix` is unchanged — still relevant.
