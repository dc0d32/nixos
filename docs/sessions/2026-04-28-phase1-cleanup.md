# 2026-04-28 — Phase 1 cleanup

## Goal

First pass of a code-review-driven cleanup. Fix definite bugs, remove orphan
files, and shrink the surface area before tackling structural improvements in
Phase 2.

## Context

Read-only review identified ~15 P0/P1 issues across the flake (bugs, partial
migrations, dead code). This session executes Phase 1: the strict subset that
either (a) is or could become a runtime fault, or (b) is unambiguously dead
code with no functional risk to remove.

Phase 2 (parametrize lock wallpaper path, wire VolumeOsd via QML PipeWire
subscribe, drop nixvim input, dedupe direnv, fix WSL host overrides, fix
wallpaper default) is deferred to a separate session for verification
isolation.

## Changes

### 1. `modules/home/desktop/quickshell/qml/shell.qml` — lock IPC + dead launcher

The `IpcHandler { target: "lock"; function lock() { lock.lock(); } }` block
referenced `lock` which collided with the IPC handler's own function name.
The outer `LockScreen { id: lock }` was meant to be the target but the inner
identifier shadowed it. Renamed the LockScreen `id` to `lockScreen` so the
handler can call `lockScreen.lock()` unambiguously. niri's keybind
(`quickshell ipc call lock lock`) is unchanged.

Also removed the dead `IpcHandler { target: "launcher"; function toggle() {} }`
block — `Launcher.qml` was never instantiated and `Mod+Space` in niri runs
`fuzzel` directly. The handler's empty body confirmed it was a half-finished
migration left behind.

### 2. `overlays/nvim-treesitter-pin.nix` — real hash

Replaced `prev.lib.fakeHash` with the real
`sha256-9GI22/cwoJWOO7jvRpW67s/x6IoahNZkMpBb58rO31k=` (computed via
`nix-prefetch-url --unpack` + `nix hash convert --to sri`). First build on a
fresh host was guaranteed to fail before this change.

### 3. `modules/nixos/desktop/quickshell.nix` — deleted entirely

The file was orphaned (not imported by `modules/nixos/default.nix`) and its
contents were either dead (lightdm block, force-disabled by `login-ly.nix`)
or duplicated (xdg.portal, environment.systemPackages, dbus, polkit — all
already provided by `modules/nixos/desktop/niri.nix`). Quickshell itself is
a home-manager package; no system-level config is required when both niri
and quickshell are enabled together.

### 4. Orphan deletions (`git rm`)

- `modules/home/desktop/cursor.nix` — empty `lib.mkIf` stub; cursor config
  already lives in `modules/home/desktop/extras.nix`. Import removed from
  `modules/home/default.nix`.
- `modules/home/desktop/stasis/stasis.rune` — static config file overridden
  at runtime by `modules/home/desktop/idle.nix` writing
  `xdg.configFile."stasis/config.rune"` with different timings. Never read.
  The `stasis/` directory is now empty and `git rm` has removed it from
  the tree.
- `modules/home/desktop/quickshell/qml/lock/lock-wrapper.sh` — never
  referenced; niri keybind shells out to `quickshell ipc call lock lock`
  directly.
- `modules/home/desktop/quickshell/qml/pam/password.conf` — would be
  meaningless even if used: PAM only reads `/etc/pam.d/`, not user config.
  `LockContext.qml` already routes auth through `config: "login"` (system
  PAM service). The orphaned file is a leftover from a discarded plan.
- `modules/home/desktop/quickshell/qml/launcher/Launcher.qml` — fully
  implemented but never instantiated in `shell.qml`. Decision: defer the
  launcher entirely to `fuzzel` (no plans to re-introduce; if a future
  in-shell launcher is desired it'll be a fresh design).
- `modules/home/desktop/quickshell/qml/IdleController.qml` — never
  instantiated; idle/lock is driven by `stasis` per
  `2026-04-26-quickshell-idle-daemon.md`.

`modules/home/desktop/quickshell/qml/qmldir` updated to drop the
`Launcher` and `IdleController` entries.

### 5. `modules/home/git.nix` — false positive, no change

Initial review flagged `programs.git.settings` as invalid; the actual home-
manager schema in this nixpkgs version uses exactly that name. The legacy
`userName` / `userEmail` / `extraConfig` / `aliases` options now warn as
deprecated. The original file was canonical; no edit needed.

## Verification

```sh
nix flake check                                                 # passes
nix build .#nixosConfigurations.laptop.config.system.build.toplevel
nix build .#homeConfigurations."p@laptop".activationPackage
```

All three succeed with no new warnings. Pre-existing warnings (unknown
`mylib` flake output, missing `meta` on apps) are not Phase-1 regressions.

No `switch` performed — user runs that on their schedule.

## Lessons

1. **Verify HM option schemas before declaring them broken.** The git.nix
   "bug" was a false positive caused by reading a deprecation comment
   somewhere in memory and not double-checking against the actual module
   source. Cost: one wasted edit + revert. Future code reviews should
   confirm the option name with `nix eval` or a HM source read before
   ranking the issue.
2. **Trust `git rm` to clean empty directories.** No need to `rmdir`
   afterwards — git does it implicitly when the last tracked file leaves.
3. **The flake-only-sees-tracked-files rule applies to modifications too,
   in the sense of `nix-env`-style read paths**, but Nix's flake mode
   reads the working tree state of tracked files even when unstaged.
   `git add` is required for *new* files (untracked → invisible) but not
   for edits to existing tracked files. Habit of `git add` before build
   is still wise.

## Next

Phase 2 (deferred):
- Parametrize `LockScreen.qml` wallpaper path via `Quickshell.env("HOME")`.
- Wire `VolumeOsd` to react to PipeWire/wpctl events from inside QML
  (long-running `pactl subscribe` process).
- Remove unused `nixvim` flake input.
- Deduplicate `programs.direnv` (keep `direnv.nix`, drop the block in
  `zsh.nix`).
- Replace stale "swayidle" comments with stasis equivalents in all
  `variables.nix` files.
- Set `hardwareHacking.enable = false` and `audio.easyeffects.enable = false`
  explicitly on both WSL hosts; teach `apps/new-host.nix --wsl` to do the
  same and to substitute the username in the wallpaper path.
- Default `wallpaper.directory` to `${config.home.homeDirectory}/.wallpaper`
  in `modules/home/desktop/wallpaper.nix`; remove the literal-path entry
  from `hosts/_template/variables.nix`.
