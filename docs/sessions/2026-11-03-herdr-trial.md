# 2026-11-03 — herdr trial alongside tmux/psmux

## Decision

Add [herdr](https://herdr.dev) (agent-aware multiplexer, `herdrdev/herdr`,
v0.9.5) on every account and on the Windows host, as a *trial*. tmux and
psmux are untouched; nothing is removed.

## Shape

- `overlays/herdr.nix` — packages the official release binary
  (`fetchurl`, one hash per platform). Not built from source: upstream
  needs Rust 1.96.1 + Zig 0.16 (nixpkgs has Rust 1.95) and a new flake
  input. The Linux binaries are static-pie, so no patching is needed.
- `flake-modules/herdr.nix` — publishes `flake.lib.herdrSettings` and the
  `homeManager.herdr` module (package + `~/.config/herdr/config.toml`).
  In the `home-base` bundle, so all accounts and hosts (incl. macOS, WSL)
  get it.
- `flake-modules/windows/windows.nix` — `herdr` added to the Scoop list
  (Scoop `main` carries it; same release asset), `herdr.toml` rendered
  from the same `herdrSettings` and deployed by `hm_win` to
  `%APPDATA%\herdr\config.toml`.

## Config, in tmux terms

Prefix and `h/j/k/l` focus are herdr defaults and already match. Added
`prefix+|` (alongside `v`), `prefix+H/J/K/L` resize, no name prompt for new
tabs, a tab-row status area (host + date/time, with Font Awesome icons)
mirroring the tmux bar, glyph-shaped agent status for RDP legibility, agent
names on pane borders, Nord-toned sidebar rows, in-app toasts, sound off.
`theme.name = "nord"` is herdr's built-in Nord, which matches the niri
desktop (waybar #2e3440/#eceff4/#88c0d0, mako #4c566a) exactly.

Rounded pane corners are NOT possible in 0.9.5: divider corners are
hard-coded `┌┐└┘` in `src/ui/panes.rs` with no setting, and upstream closed
the border-styling request (#1794) as not planned (issues are bug-only).

## Gotchas

- The config is a read-only store symlink: herdr's settings screen can't
  write it, so `onboarding = false` is set (onboarding persists its answer
  into config.toml). Run `herdr integration` per machine for agent hooks.
- Validate any edit with `herdr config check` (exit 1 + diagnostics on a
  bad key or format). Unknown keybindings are *disabled*, not fatal.
- Not verified: macOS (evaluates, can't run here) and herdr's mouse
  handling under ConPTY on Windows (psmux's mouse had to be turned off
  there; herdr's default `mouse_capture = true` is left on).
- Windows copy updates via Scoop; the Nix overlay is bumped by hand.

## Agent integrations (copilot, opencode, hermes)

`herdr integration install <agent>` writes a hook/plugin into each agent's
config so the sidebar gets session ids and authoritative state. It refuses
to run unless the agent's config dir exists.

- Linux/macOS: `home.activation.herdrIntegrations` in `flake-modules/herdr.nix`.
- Windows: an unnumbered block in `setup.ps1` (`flake-modules/windows/windows.nix`),
  after the Scoop/shim steps.
- Both: idempotent (skip when `integration status` says `current`), install
  where the dir exists, create the dir for copilot/opencode when the agent is
  on PATH but never ran, never for hermes (needs one run first). Failures warn.
- Caveats: native Windows and WSL are separate herdr installs. The Windows
  step is built but untested on Windows, and that herdr picks the copilot
  `.ps1` hook there is unverified. Hermes is not on pb-1.
