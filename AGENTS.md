# AGENTS.md

## Hard rules

- **Never `git commit` or `git push` without explicit user instruction.**
- Do not wire home-manager into NixOS as a module — HM is standalone
  by design.
- Do not add nix-darwin, a secrets framework (sops-nix/agenix), or
  move configs to a separate dotfiles repo unless asked.
- Line endings must stay LF (enforced by `.gitattributes`).

## Key commands

```sh
# Rebuild NixOS (user runs sudo, not the agent)
sudo nixos-rebuild switch --flake .#pb-x1

# Rebuild user environment
home-manager switch --flake .#'p@pb-x1'

# Format
nix fmt

# Evaluate without building
nix flake check

# Agent-side smoke build (no activation, no sudo)
nix build .#nixosConfigurations.pb-x1.config.system.build.toplevel
nix build .#homeConfigurations.'p@pb-x1'.activationPackage
```

## Architecture

- `flake.nix` is a thin [flake-parts](https://flake.parts) entry point
  that imports the dendritic tree under `flake-modules/` via
  [import-tree](https://github.com/vic/import-tree).
- Every Nix file under `flake-modules/` is a top-level flake-parts
  module. Each feature contributes to
  `flake.modules.<class>.<feature>` for whichever class(es) it applies
  to (`nixos`, `homeManager`, or both as a cross-class module).
- `flake-modules/hosts/pb-x1.nix` is the host bridge for the primary
  laptop: it picks which
  feature modules to import and sets per-host option values.
- **Importing IS enabling.** There is no per-feature `enable` flag and
  no `variables.nix`. Hosts that don't want a feature simply don't
  import it.

## Module conventions

- Pure-leaf modules (no host-tunable data) write
  `flake.modules.<class>.<name> = { … };` at the top level.
- Modules with host-tunable data declare top-level `options.<ns>` and
  contribute via
  `config.flake.modules.<class>.<name> = let cfg = config.<ns>; in { … };`.
  The inner module's `config` shadows the outer one — let-bind `cfg`
  from the **outer** flake-parts `config`.
- When a file mixes `options` with `flake.modules.*`, the latter MUST
  be wrapped in an explicit `config = { … };` block.
- Use `lib.mkDefault` for policy values so hosts can override without
  `mkForce` conflicts.
- Every module file begins with a header explaining (1) why it exists
  and (2) the retirement condition (when it would be safe to delete).
- Overlays live in `overlays/<name>.nix`, registered in
  `overlays/default.nix`. Same (why, retirement) header rule applies.

## Cross-module signals

When feature A needs to know whether feature B is loaded (e.g.
`quickshell` checks `biometrics.enable` to decide lockscreen hints),
feature B declares `options.B.enable = mkOption { default = false; };`
and sets `config.B.enable = lib.mkDefault true;` inside its own module.
Importing B publishes the signal; non-importers get false. No host
coupling required.

## Flake is git-tracked — new files must be staged

Nix flake builds only see **git-tracked** files. After creating any
new file, run `git add <file>` before any rebuild or build, or it will
be silently excluded.

## Deploy split: NixOS vs home-manager

- System-level (`flake.modules.nixos.*`): PipeWire, kernel, services,
  boot — `sudo nixos-rebuild switch --flake .#pb-x1`.
- User-level (`flake.modules.homeManager.*`): dotfiles, EasyEffects,
  quickshell, zsh, alacritty — `home-manager switch --flake .#'p@pb-x1'`.
- Editing a `flake.modules.nixos.*` module and only running
  home-manager (or vice versa) silently has no effect.

## Host-specific assets

Hardware-specific files (audio presets, IRS impulse responses,
hardware-configuration.nix) live under `hosts/<hostname>/`, not in
`flake-modules/`. They are referenced from the host bridge as paths
fed into the relevant module's options:

```nix
# flake-modules/hosts/pb-x1.nix
audio.easyeffects = {
  presetsDir = ../../hosts/pb-x1/audio-presets;
  irsDir     = ../../hosts/pb-x1/audio-irs;
  preset     = "X1Yoga7-Dynamic-Detailed";
};
```

## EasyEffects specifics

- Preset JSON files → `~/.config/easyeffects/output/` (via
  `xdg.configFile`).
- IRS impulse response files → `~/.local/share/easyeffects/irs/` (via
  `xdg.dataFile`) — **required**, not optional; the convolver stage in
  every preset references its IRS by `kernel-name`.
- Auto-load is set via `~/.config/easyeffects/db/easyeffectsrc`
  (`[Presets] lastLoadedOutputPreset=<name>`). The
  `last-used-output-preset` text file is **not** read by EasyEffects.
- The existing `easyeffectsrc` will block deployment unless
  `force = true` is set on that `xdg.configFile` entry.

## Quickshell (QML bar/shell)

- QML files live in `flake-modules/quickshell/qml/` and are deployed
  via `xdg.configFile."quickshell"` with `recursive = true`.
- Every new QML type must be registered in
  `flake-modules/quickshell/qml/qmldir` or it won't be found at
  runtime.
- New files must be `git add`-ed before deploying (flake build ignores
  untracked files).
- Use Quickshell for as many shell features as possible. Ask explicit
  user permission before reaching for swaybar/waybar etc.

## Adding a new host

There is no scaffolder. To add a host:

1. Create `flake-modules/hosts/<name>.nix` modeled after `pb-x1.nix`
   (full desktop) or `wsl.nix` (headless / multi-config).
2. Generate `hosts/<name>/hardware-configuration.nix` via
   `sudo nixos-generate-config --show-hardware-config`.
3. Pick which feature modules to import; set their option values.
4. `git add` everything new and build.

## Session log

After a substantive session (new subsystem, migration, architectural
decision), write `docs/sessions/YYYY-MM-DD-<slug>.md`. Do not edit
past session files.
