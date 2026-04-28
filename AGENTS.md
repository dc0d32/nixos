# AGENTS.md

## Hard rules

- **Never `git commit` or `git push` without explicit user instruction.**
- Do not wire home-manager into NixOS as a module — HM is standalone by design.
- Do not add nix-darwin, a secrets framework (sops-nix/agenix), or move configs to a separate dotfiles repo unless asked.
- Do not edit `hosts/_template/` or `homes/_template/` — scaffold new hosts with `nix run .#new-host -- <name>`.
- Line endings must stay LF (enforced by `.gitattributes`).

## Key commands

```sh
# Rebuild NixOS system
sudo nixos-rebuild switch --flake .#<hostname>
# user needs to run sudo commands. Do not attempt to run them yourself

# Rebuild user environment (NixOS and macOS)
home-manager switch --flake .#<user>@<hostname>

# Current machine (laptop)
sudo nixos-rebuild switch --flake .#laptop
home-manager switch --flake .#"p@laptop"

# Format
nix fmt

# Evaluate without building
nix flake check
```

## Architecture

- `flake.nix` auto-discovers `hosts/` and `homes/` — no manual registration needed.
- `lib/default.nix` provides `mkHost` / `mkHome`. Variables flow via `specialArgs`/`extraSpecialArgs` as `variables`.
- `hosts/<hostname>/variables.nix` is the single source of truth for all feature flags on that host. It is plain Nix (no `lib`), imported directly.
- `homes/<user>@<hostname>/home.nix` is merged on top of host variables; use it for per-user overrides on a shared machine.
- `modules/nixos/default.nix` and `modules/home/default.nix` are the aggregators — add new module imports there.

## Module conventions

- Gate every module on `lib.mkIf (variables.<ns>.<name>.enable or false)`.
- Use `lib.mkDefault` for policy values in shared modules so hosts can override without `mkForce` conflicts.
- Linux-only home modules must be wrapped in `lib.optionals isLinux` in `modules/home/default.nix`.
- Overlays go in `overlays/<name>.nix`, registered in `overlays/default.nix`. Each must document (1) why it exists and (2) when it is safe to delete.

## Flake is git-tracked — new files must be staged

Nix flake builds only see **git-tracked** files. After creating any new file, run `git add <file>` before `home-manager switch` or `nixos-rebuild`, or it will be silently excluded.

## Deploy split: NixOS vs home-manager

- System-level changes (PipeWire, WirePlumber, kernel params, services): `sudo nixos-rebuild switch --flake .#laptop`
- User-level changes (dotfiles, EasyEffects, quickshell, zsh, cursor): `home-manager switch --flake .#"p@laptop"`
- Getting this wrong (e.g. editing `modules/nixos/` then only running home-manager) will silently have no effect.

## Host-specific assets

Hardware-specific files (audio presets, IRS impulse responses) live under `hosts/<hostname>/`, not in `modules/`. They are passed to the generic module via `variables`:

```nix
# hosts/laptop/variables.nix
audio.easyeffects = {
  presetsDir = ./audio-presets;   # hosts/laptop/audio-presets/
  irsDir     = ./audio-irs;       # hosts/laptop/audio-irs/
  preset     = "X1Yoga7-Dynamic-Detailed";
};
```

## EasyEffects specifics

- Preset JSON files → `~/.config/easyeffects/output/` (via `xdg.configFile`)
- IRS impulse response files → `~/.local/share/easyeffects/irs/` (via `xdg.dataFile`) — **required**, not optional; the convolver stage in every preset references its IRS by `kernel-name`.
- Auto-load is set via `~/.config/easyeffects/db/easyeffectsrc` (`[Presets] lastLoadedOutputPreset=<name>`). The `last-used-output-preset` text file is **not** read by EasyEffects.
- The existing `easyeffectsrc` will block deployment unless `force = true` is set on that `xdg.configFile` entry.

## Quickshell (QML bar/shell)

- QML files live in `modules/home/desktop/quickshell/qml/` and are deployed via `xdg.configFile."quickshell"` with `recursive = true`.
- Every new QML type must be registered in `modules/home/desktop/quickshell/qml/qmldir` or it won't be found at runtime.
- New files must be `git add`ed before deploying (flake build ignores untracked files).
- Use QuickShell for as many shell features as possible. Ask explicit user permissions before using swaybar etc.

## Session log

After a substantive session (new subsystem, migration, architectural decision), write `docs/sessions/YYYY-MM-DD-<slug>.md`. Do not edit past session files.
