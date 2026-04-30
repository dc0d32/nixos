# Instructions for Claude Code

This repo is a personal NixOS + home-manager flake organized as a
**dendritic flake** (see `README.md` for the user-facing description).
Before doing anything non-trivial, read the most recent files under
`docs/sessions/`, especially the dendritic-migration notes — they are
the canonical record of architectural decisions and rationale.

## Hard rules

- **Do not commit or push changes unless explicitly asked.** Make edits
  and verify builds, but always wait for explicit user authorization
  before running `git commit` or `git push`.
- **Do not move to a separate dotfiles repo.** The user explicitly
  chose to keep everything declarative in this nix repo under
  `flake-modules/`.
- **Do not wire home-manager into NixOS as a module.** HM runs
  standalone so the same user modules can apply on macOS later.
- **Do not add nix-darwin** without the user asking.
- **Do not introduce a secrets framework** (sops-nix/agenix) unless
  asked.
- **Line endings must stay LF.** `.gitattributes` enforces this; don't
  relax.

## Conventions

- Every Nix file under `flake-modules/` is a top-level
  [flake-parts](https://flake.parts) module, auto-imported via
  [import-tree](https://github.com/vic/import-tree).
- New features go in `flake-modules/<feature>.nix` and contribute to
  `flake.modules.<class>.<feature>` for whichever class(es) apply
  (`nixos`, `homeManager`, or both).
- **Importing IS enabling.** Hosts opt in to a feature by listing
  `config.flake.modules.<class>.<feature>` in their `imports`. There is
  no per-feature `enable` gate.
- Modules that need host-tunable data declare top-level
  `options.<ns>` and read them inside
  `config.flake.modules.<class>.<feature> = let cfg = config.<ns>; in { … };`.
  The inner module's `config` parameter shadows the outer one — let-bind
  cfg from the **outer** flake-parts `config`.
- When a file mixes `options` with `flake.modules.*`, the latter MUST
  be wrapped in an explicit `config = { … };`. Pure-leaf modules
  without options can write `flake.modules.*` at the top level.
- Format with `nix fmt` (nixpkgs-fmt) before committing.
- In shared modules, use `lib.mkDefault` for policy values so hosts can
  override with plain assignments. Reserve `mkForce` for genuine
  override needs.
- Package overrides (pins, patches, upstream bumps awaiting nixpkgs)
  live in `overlays/<name>.nix`, one per file, registered in
  `overlays/default.nix`. Every overlay file MUST carry (1) a comment
  explaining *why* the override exists and (2) a retirement condition.

## Cross-module signals

When feature A needs to know whether feature B is loaded, feature B
declares `options.B.enable = mkOption { default = false; };` and sets
`config.B.enable = lib.mkDefault true;` inside its own module body.
Importing B publishes the signal; non-importers see false. This keeps
hosts from re-declaring booleans.

## Flake is git-tracked — new files must be staged

Nix flake builds only see **git-tracked** files. After creating any
new file, `git add` it before running `nixos-rebuild` or
`home-manager switch`, or it will be silently excluded.

## Deploy split: NixOS vs home-manager

- System-level changes (`flake.modules.nixos.*`): user runs
  `sudo nixos-rebuild switch --flake .#pb-x1`.
- User-level changes (`flake.modules.homeManager.*`): user runs
  `home-manager switch --flake .#'p@pb-x1'`.
- The agent runs `nix build` only; the user runs anything that needs
  sudo or activation.

## Session log

When you complete a substantive session (architectural change, new
subsystem, migration), write a new file in
`docs/sessions/YYYY-MM-DD-<slug>.md` describing decisions and
rationale. Do not edit past session files except to correct factual
errors.

## Quick orientation

- `flake.nix` — inputs and flake-parts entry; imports the dendritic tree.
- `flake-modules/` — every feature module; one concern per file.
- `flake-modules/hosts/pb-x1.nix` — host bridge for the primary
  laptop: imports + per-host option values.
- `hosts/pb-x1/` — `hardware-configuration.nix` and host-specific
  asset directories (audio presets, IRS).
- `overlays/` — package overrides; see Conventions.
- `packages/` — custom package definitions.
- `README.md` — user-facing layout, install, day-to-day commands.
