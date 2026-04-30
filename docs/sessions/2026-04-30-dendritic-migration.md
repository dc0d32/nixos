# 2026-04-30 — Dendritic-pattern migration plan

## Goal

Refactor this repo to follow the [dendritic
pattern](https://github.com/mightyiam/dendritic): a top-level
flake-parts configuration in which every Nix file (other than entry
points) is a top-level module of the same `class`. Each top-level
module owns a single feature across every consumer (NixOS, standalone
home-manager, devShell, custom packages, apps).

The migration is **incremental** — each commit lands one feature and
leaves the laptop fully buildable. The final state has no
`hosts/<host>/variables.nix`, no `lib/mkHost`, no
`modules/{nixos,home}/default.nix` aggregators, and no `specialArgs`
pass-thru.

## User-locked preferences

These were settled at the start of the migration session and apply to
every subsequent commit:

1. **Strategy: incremental.** One commit per migrated feature.
   Substrate-introduction is its own commit. The laptop must build
   between every commit.
2. **Substrate: `flake-parts` + `vic/import-tree`.** Matches the
   canonical example at `mightyiam/dendritic/example/`. `import-tree`
   walks the dendritic module tree and feeds every `.nix` file to
   `flake-parts.lib.mkFlake` as a top-level module.
3. **Hosts: laptop only.** Structure must support adding more hosts
   without restructuring, but no speculative scaffolding for hosts
   that don't exist.
4. **`variables.nix`: eliminate it.** The end-state `hosts/laptop.nix`
   (or equivalent) is just a list of `services.foo.enable = true`
   feature toggles plus per-host data set on those features'
   options. Per-host secrets/data live alongside the feature module
   that consumes them, not in a giant central blob.
5. **Commit granularity: one commit per migrated feature.** Bisect
   stays useful, review surface stays small, every commit boundary is
   a green build.
6. **Dendritic tree location during migration: `./flake-modules/`.**
   `import-tree` walks `./flake-modules/`. The existing
   `./modules/{nixos,home}/` tree stays where it is and shrinks as
   features migrate out of it. Optional final cleanup commit may
   rename `./flake-modules/` → `./modules/` once the legacy tree is
   gone.

## Why dendritic

The two pain points it solves for this repo:

- **`specialArgs` `variables` pass-thru.** Today every NixOS / HM
  module reads `variables` from `specialArgs`, which we have to thread
  through `lib.nixosSystem` and `home-manager.lib.homeManagerConfiguration`
  manually in `lib/mkHost` / `lib/mkHome`. In dendritic, every file
  can read/write top-level `config`, so a feature module that needs a
  per-host knob just declares an option and reads it back on the same
  `config` — no plumbing, no `specialArgs`.

- **Module-class duality.** Today a single feature like *audio* is
  split into `modules/nixos/audio/pipewire.nix` (system bits) and
  `modules/home/audio/easyeffects.nix` (user bits). They share host
  data (preset path, IRS dir) only via the central
  `variables.nix`. In dendritic, one file `flake-modules/audio.nix`
  declares both `flake.modules.nixos.audio = { ... }` and
  `flake.modules.homeManager.audio = { ... }`, and the per-host data
  it needs is declared as an option on its own module — set once,
  read by both sides.

## Substrate (commit 1) shape

Modeled on `mightyiam/dendritic/example/`, plus a home-manager
counterpart.

`flake.nix` becomes minimal:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    import-tree.url = "github:vic/import-tree";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = { url = "github:sodiboo/niri-flake"; inputs.nixpkgs.follows = "nixpkgs"; };
    nixos-wsl = { url = "github:dc0d32/nixos-aarch64-wsl"; inputs.nixpkgs.follows = "nixpkgs"; };
  };
  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; }
      (inputs.import-tree ./flake-modules);
}
```

The dendritic substrate under `./flake-modules/` for commit 1:

- `flake-parts.nix` — imports `inputs.flake-parts.flakeModules.modules`
  to enable the `flake.modules.<class>.<name>` machinery used in
  every feature module.
- `systems.nix` — declares `systems = [ "x86_64-linux" "aarch64-linux" ];`.
- `nixos.nix` — declares `options.configurations.nixos.<name>.module`
  and builds `flake.nixosConfigurations` from it. Lifted directly
  from the canonical example.
- `home-manager.nix` — analog of `nixos.nix` for standalone HM:
  declares `options.configurations.homeManager.<name>` (with `pkgs`
  + `module` sub-options) and builds `flake.homeConfigurations`.
- `hosts/laptop.nix` — sets `configurations.nixos.laptop.module` to a
  module list whose only initial entry is the legacy
  `./modules/nixos/default.nix` aggregator + the existing
  `./hosts/laptop/configuration.nix`. Same for `homeManager.p@laptop`.
- `apps.nix` — keeps the existing `nix run .#new-host` app.
- `dev-shell.nix` — keeps the existing devShell.
- `formatter.nix` — keeps `nixpkgs-fmt` as the formatter.

Commit 1 deletes nothing. It wraps `lib/mkHost` and `lib/mkHome`
inside `hosts/laptop.nix`. Subsequent commits replace those wrappers
with feature modules and eventually delete `lib/`, `variables.nix`,
and the aggregators.

## Migration order (proposed; subject to revision per-feature)

1. Substrate (this commit).
2. **Trivial leaf modules first**: `git`, `tmux`, `direnv`, `fonts`,
   `locale`. Each becomes one `flake-modules/<name>.nix` that
   declares `flake.modules.{nixos,homeManager}.<name>` and removes
   itself from the corresponding aggregator's `imports`.
3. **`gpu`, `power`, `networking`, `nix-settings`, `system-utils`,
   `users`** — system-only, low coupling.
4. **`audio`** (pipewire + easyeffects) — first cross-class feature,
   exercises the host-data-as-option pattern (preset path, IRS dir,
   autoload device).
5. **`battery`** — exercises the option-default-from-host pattern
   (charge thresholds, swap size).
6. **`desktop`** subtree (`niri`, `quickshell`, `waybar`, `idle`,
   `wallpaper`, `polkit-agent`, `extras`, `login-ly`).
7. **`apps`** (`chrome`, `bitwarden`, `vscode`).
8. **`cad/freecad`**, **`hardware-hacking`**, **`biometrics`**.
9. **`shell/zsh`, `editor/neovim`, `editor/vscode`,
   `terminal/alacritty`, `tools/*`**.
10. **`wsl`** module — keeps the WSL host story consistent even
    though `wsl` hosts are currently unbuilt.
11. **Cleanup**: delete empty
    `modules/{nixos,home}/default.nix`, the now-unused
    `lib/{mkHost,mkHome,mkAllHosts,mkAllHomes,loadVars}`, and
    `hosts/laptop/variables.nix` (its remaining values like
    `hostname`, `system`, `stateVersion`, `timezone`, `keymap` are
    moved into `hosts/laptop.nix` directly).

## Risks and mitigations

- **Eval regression between substrate and last legacy import.** The
  laptop's `nixosConfigurations.laptop.config.system.build.toplevel`
  hash is captured pre-substrate; commit 1 must produce the same
  store path. Verified with `nix build` before commit.
- **Closure-equivalence vs. byte-equivalence.** Substrate commit (1)
  and trivial-leaf migrations contributing only `programs.*` /
  `xdg.configFile` produce *byte-identical* HM and NixOS toplevel
  hashes. Migrations that touch list-valued options merged across
  modules — most importantly `home.packages` and
  `environment.systemPackages` — change the union order in
  `buildEnv`, producing a different `home-manager-path` /
  `system-path` store hash even though the package set is identical.
  Verified by diffing the `pkgs` JSON in the derivation env: same
  paths, different order. The fontconfig cache (which hashes its
  output filenames by their path) also regenerates accordingly.
  Closure references and content under each derivation remain
  identical. From the `tools` batch onward, the regression check is
  relaxed from "same store hash" to "same closure refs + identical
  content modulo derivation re-ordering".
- **Standalone home-manager has no canonical dendritic example.** The
  `home-manager.nix` substrate file is novel — modeled by transcribing
  the example's `nixos.nix` and substituting
  `home-manager.lib.homeManagerConfiguration` for `lib.nixosSystem`,
  with explicit `pkgs` because HM doesn't infer one from
  `nixpkgs.hostPlatform`. Verified by building
  `homeConfigurations."p@laptop".activationPackage`.
- **`variables.nix` removal is the final commit, not the first.**
  Any feature commit that hasn't migrated yet still reads
  `specialArgs.variables`, so `variables.nix` must remain readable
  through the entire migration window. The substrate commit's
  `hosts/laptop.nix` wrapper passes `variables` through unchanged.
- **`./modules/` and `./flake-modules/` coexist** for the duration of
  the migration. `import-tree` only walks `./flake-modules/`, so
  there's no double-import risk; the legacy tree is reached only via
  explicit `imports = [ ./modules/nixos ];` in
  `hosts/laptop.nix`. As features migrate, that imports list
  shrinks until the aggregator is empty and can be deleted.
