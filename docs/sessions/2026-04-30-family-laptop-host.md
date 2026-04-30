# 2026-04-30 — family-laptop host: scaffold + parental-control plan

## Goal

Add a shared family laptop with three accounts (`p` admin, `m` and `s`
kids) and full parental controls. Modeled loosely on Windows Family
Safety: per-user app sets, time-of-day login windows, daily screen-time
budgets, optional web filtering, and login-activity visibility for the
admin.

## What landed in this commit

- `hosts/family-laptop/hardware-configuration.nix` — **placeholder**.
  Sentinel UUID `00000000-…`, generic kernel module list. Exists so
  the flake evaluates and the toplevel derivation builds for
  smoke-testing on pb-x1. NOT BOOTABLE. Must be regenerated on the
  real hardware via `sudo nixos-generate-config --show-hardware-config
  > hosts/family-laptop/hardware-configuration.nix` before any
  `sudo nixos-rebuild switch`.
- `flake-modules/hosts/family-laptop.nix` — host bridge. Emits one
  NixOS configuration (`family-laptop`) and three home-manager
  configurations (`p@family-laptop`, `m@family-laptop`,
  `s@family-laptop`) from a single file.
- Three NixOS users defined in one `users.users = { p = …; } //
  lib.genAttrs kidUsers …` block (a single module-attrset literal
  can't carry two separate `users.users = …` assignments — only
  cross-module merging coalesces them).
- `users.primary = "p"` so feature modules that operate on the
  primary user (currently none imported by this host, but the
  declared option is mandatory) target the right account.
- `familyActivity` wrapper script — `family-activity [days]` filters
  `systemd-logind` journal events for `m`/`s` session opens/closes.
  No separate log file: NixOS already journals all PAM session events
  and `p` reads the journal via `wheel`. Avoids a separate log
  pipeline and rotation logic.
- `initialPassword = "changeme"` on all three accounts. Per the
  AGENTS.md note that this is visible in the Nix store; users prompted
  to change at first login. Trade-off accepted: no out-of-band
  password files needed before first deploy.

## Module set per user

- **p** (admin, full mirror of pb-x1): git, tmux, direnv, fonts,
  btop, build-deps, gh, ai-cli, hardware-hacking, polkit-agent,
  chrome, bitwarden, vscode, alacritty, zsh, desktop-extras,
  wallpaper, idle, freecad, neovim, niri, quickshell.
- **m, s** (kids, restricted): zsh, alacritty, chrome, fonts, niri,
  quickshell, wallpaper, idle, polkit-agent, desktop-extras, btop,
  neovim. No vscode, no freecad, no bitwarden, no ai-cli, no
  build-deps, no hardware-hacking. Same desktop session as p so the
  box looks the same to whoever's logged in.

## NixOS feature modules NOT imported

- `audio` — EasyEffects presets are X1-Yoga-specific. PipeWire still
  runs because niri pulls in its dependencies; just no convolver/EQ.
- `battery` — hwconfig isn't real yet; charge thresholds and resume
  device are device-specific.
- `hardware-hacking` (NixOS side) — kids don't need
  `dialout`/`plugdev`. Revisit if p wants serial/USB device access.
- `biometrics` — no fingerprint reader assumed; revisit after
  hwconfig.

## Deliberately deferred (separate follow-up commits)

1. **timekpr-next** packaging. Not in nixpkgs (verified in this
   session). Plan: `pkgs/timekpr-next/default.nix` + overlay
   registration as one commit, then wire into family-laptop with
   per-kid policy (m: 06:00–21:00, 4h/day budget; s: 07:00–22:00,
   6h/day) as a second commit. Each commit must build standalone.
2. **Web filtering / DNS logging.** User chose to skip both for v1.
   If reconsidered, the natural building block is a local resolver
   (`unbound` with `extended-statistics`) — installing it gives
   query logs for free; adding a blocklist later is a one-option
   change.
3. **Real hardware-configuration.nix.** Generated on first boot of
   the actual box.
4. **Per-host SSH access (so admin can `home-manager switch
   --flake .#'p@family-laptop'` from pb-x1).** Not in scope for v1.

## Decisions and rationale

- **One bridge file emits multiple HM configs** (same pattern as
  `flake-modules/hosts/wsl.nix`): the three HM configs share a `pkgs`
  instance and most boilerplate, so duplicating into three files
  invites drift. p's HM module is inlined; kids' HM module comes from
  `mkKidHmModule` so adding/removing a kid is a one-line list edit.
- **Two-step HM-attrs assembly.** `configurations.homeManager =
  { p = …; } // builtins.listToAttrs (…)` rather than two separate
  top-level assignments to the same option (which would conflict at
  the flake-parts module level the same way `users.users = …` did
  inside the NixOS submodule).
- **No web filtering even though Windows Family does it.** User
  preference. The host scaffolding doesn't preclude adding it later;
  it just doesn't carry the dependencies.
- **No screenshots / clipboard surveillance.** Pushed back on the
  Windows Family pattern. `family-activity` shows session windows;
  it does not log keystrokes, browsing, or screen content.
- **Same `initialPassword = "changeme"` for all three.** Visible in
  the Nix store; this is fine for a fresh install where the box is
  about to be set up by p in person. AGENTS.md acknowledges this
  trade-off.

## Build verification

- `nix eval .#nixosConfigurations` →
  `["family-laptop","pb-x1","wsl","wsl-arm"]`.
- `nix eval .#homeConfigurations` →
  `["m@family-laptop","p@family-laptop","p@pb-x1","p@wsl","p@wsl-arm","s@family-laptop"]`.
- `nix build` of `family-laptop.config.system.build.toplevel` and
  all three HM `activationPackage`s succeeded.
- `pb-x1`, `wsl`, `p@pb-x1` closures byte-identical to the
  pre-change baseline (no cross-host bleed).

## Retirement condition for the placeholder hwconfig

Replace once the real machine is provisioned. Header comment in the
file says so explicitly; building with the sentinel UUID will fail at
boot, which is the protection.
