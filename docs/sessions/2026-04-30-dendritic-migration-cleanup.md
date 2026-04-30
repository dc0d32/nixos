# 2026-04-30 — dendritic migration final cleanup

Closes the dendritic migration started in
`2026-04-30-dendritic-migration.md`. All feature modules have been
moved to `flake-modules/<feature>.nix` and the legacy scaffolding is
now removed.

## What was deleted

- `lib/default.nix` — the old `mkHost` / `mkHome` builders. The flake
  now builds `nixosConfigurations` and `homeConfigurations` directly
  via flake-parts in `flake-modules/{nixos,home-manager}.nix`.
- `modules/` — entire tree. The `modules/nixos/default.nix` and
  `modules/home/default.nix` aggregators no longer exist; each former
  module lives in `flake-modules/<feature>.nix` and is selected by
  importing it from the host bridge.
- `apps/new-host.nix` and `flake-modules/apps.nix` — the
  `nix run .#new-host -- <name>` scaffolder. Adding a host is now four
  documented steps (see `AGENTS.md` and `README.md`).
- All `hosts/<host>/{configuration,host-packages,variables}.nix`
  — content was either inlined into `flake-modules/hosts/laptop.nix`
  (the host bridge) or replaced by per-host option assignments on the
  options declared by the relevant feature modules.
- All `homes/<user>@<host>/{home,variables}.nix` — same treatment.
- `hosts/{wsl,wsl-arm,_template}/` and `homes/{p@wsl,p@wsl-arm,_template}/`
  — dead WSL hosts and templates. The WSL feature module
  `flake-modules/wsl.nix` is preserved (not imported by laptop) so a
  future WSL host can opt back in by importing it.

## What changed (uncommitted before this commit)

- `flake-modules/hosts/laptop.nix` rewritten so every former
  `variables` reference is an inline literal: hostname, primary user,
  state version, kernel package, console keymap, bootloader settings,
  EDITOR/VISUAL session vars, and the audio preset path/IRS path/preset
  name selection. Dropped the `specialArgs.variables` /
  `extraSpecialArgs.variables` pass-through entirely.
- `flake-modules/quickshell.nix` — fixed the import-tree relative path
  for the QML subtree (`./quickshell/qml`, not `./qml`, because the
  module file sits at the parent level).
- `README.md` rewritten to describe the dendritic layout, how to add
  features, and how to add a host.
- `AGENTS.md` and `CLAUDE.md` rewritten to drop references to
  `lib/default.nix`, `mkHost`/`mkHome`, `modules/{nixos,home}/`,
  `variables.nix`, `_template`, and the new-host scaffolder.

## Verified

- `nix build .#nixosConfigurations.laptop.config.system.build.toplevel`
  produces `iyji0yr51hv1ix6s5s8l7hc0y6wbpaq3-nixos-system-laptop-…`
  — byte-identical to the pre-cleanup baseline.
- `nix build .#homeConfigurations.'p@laptop'.activationPackage`
  produces `ds56glplhvl53m19jwfzymairxyg1780-home-manager-generation`
  — byte-identical to the pre-cleanup baseline.

## Open follow-ups

None blocking. Nice-to-haves:

- Empty `homes/` directory survives the staged deletions; harmless but
  could be `rmdir`-ed.
- Cross-module signal pattern (the `biometrics.enable` option declared
  by `biometrics.nix`, consumed by `quickshell.nix`) is the only such
  signal so far. If more appear, consider documenting the pattern more
  prominently in `README.md`.
