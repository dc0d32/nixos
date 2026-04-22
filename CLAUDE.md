# Instructions for Claude Code

This repo is a personal NixOS + home-manager flake. Before doing anything
non-trivial, read
[`docs/sessions/2026-04-21-initial-scaffold.md`](docs/sessions/2026-04-21-initial-scaffold.md).
That file is the canonical design record: user preferences, architectural
decisions, and rationale live there.

## Hard rules

- **Do not move to a separate dotfiles repo.** The user explicitly chose to
  keep everything declarative in this nix repo under `modules/home/*`.
- **Do not wire home-manager into NixOS as a module.** HM runs standalone so
  the same user modules apply on macOS.
- **Do not add nix-darwin** without the user asking. Mac is home-manager-only
  by design.
- **Do not introduce a secrets framework** (sops-nix/agenix) unless asked.
- **Do not edit `hosts/_template/` or `homes/_template/` to customize a
  machine.** Scaffold a new host via `nix run .#new-host -- <name>` instead.
- **Line endings must stay LF.** `.gitattributes` enforces this; don't relax.

## Conventions

- New modules go in `modules/nixos/` or `modules/home/` and gate on
  `variables.<ns>.<name>.enable` via `lib.mkIf`.
- Aggregators are `modules/{nixos,home}/default.nix`. Add new imports there.
- Linux-only home modules must be wrapped in `lib.optionals isLinux` in
  `modules/home/default.nix`.
- Format with `nix fmt` (nixpkgs-fmt).
- Package overrides (pins, patches, upstream bumps awaiting nixpkgs) live in
  `overlays/<name>.nix`, one per file, registered in `overlays/default.nix`.
  Every overlay file MUST carry (1) a comment explaining *why* the override
  exists and (2) a retirement condition — the trigger that says it's safe to
  delete. Without (2) overlays accumulate forever. Prefer overlays over
  in-module `overrideAttrs` / `let`-bindings so overrides are centralized.

## Appending to the session log

When you complete a substantive session (architectural change, new subsystem,
migration), write a new file in `docs/sessions/YYYY-MM-DD-<slug>.md`
describing decisions and rationale. Do not edit past session files except to
correct factual errors.

## Quick orientation

- `flake.nix` — inputs and outputs, auto-discovers `hosts/` and `homes/`.
- `lib/default.nix` — `mkHost`, `mkHome`, merge rules.
- `apps/new-host.nix` — the scaffolder run by `nix run .#new-host`.
- `overlays/` — package overrides (pins/patches); see Conventions.
- `README.md` — user-facing install and day-to-day commands.
