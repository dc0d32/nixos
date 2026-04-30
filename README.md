# dc0d32 / nixos

Personal declarative config for NixOS (full system) and home-manager.
Currently configures one host: `laptop` (Lenovo X1 Yoga, x86_64-linux).

## Layout

```
flake.nix                     inputs + flake-parts substrate
flake-modules/                dendritic feature modules (one per concern)
  hosts/laptop.nix            host bridge: imports + per-host option values
  <feature>.nix               each contributes flake.modules.{nixos,homeManager}.<feature>
  quickshell/qml/             QML tree deployed to ~/.config/quickshell/
  FusionLike/                 FreeCAD auto-startup mod (Init.py + InitGui.py)
hosts/laptop/                 hardware-configuration.nix + audio presets/IRS dirs
overlays/                     custom overlays (each documents why and when to delete)
packages/                     custom package definitions
docs/                         design notes and AI session history (see docs/sessions/)
```

## Architecture

This flake follows the **dendritic pattern** (mightyiam/dendritic):

- Every Nix file under `flake-modules/` is a top-level
  [flake-parts](https://flake.parts) module, auto-imported via
  [import-tree](https://github.com/vic/import-tree).
- Each feature module contributes to `flake.modules.<class>.<feature>`
  for whichever class(es) it applies to (`nixos`, `homeManager`, or
  both as a cross-class module).
- Hosts opt in to a feature by including
  `config.flake.modules.<class>.<feature>` in their `imports = [ … ]`
  list. **Importing IS enabling** — no per-feature `enable` gate.
- Cross-module data flows through top-level `options.<ns>` declared by
  the feature module that owns the data, set on the host bridge file.
  See `flake-modules/battery.nix` for a worked example.

Design choices:

- **Home Manager is standalone** (not wired into NixOS as a module).
- **Everything declarative**: no separate dotfiles repo. User configs
  live under `flake-modules/<feature>.nix`.
- **Compositor**: niri. **Shell**: zsh. **Editor**: neovim.
  **Terminal**: alacritty.
- **No secrets module yet** — added later if needed (sops-nix or agenix).

## Day-to-day

```sh
# Rebuild NixOS (laptop is the only configured host)
sudo nixos-rebuild switch --flake .#laptop

# Rebuild user environment
home-manager switch --flake .#'p@laptop'

# Update all inputs
nix flake update

# Evaluate everything without building
nix flake check

# Format all nix files
nix fmt
```

## Adding a feature

1. Create `flake-modules/<feature>.nix` that contributes to
   `flake.modules.<class>.<feature>`. Pure-leaf modules can use
   `flake.modules.<class>.<feature> = { … };` directly. Modules that
   need host-tunable data declare `options.<ns>` plus
   `config.flake.modules.<class>.<feature> = let cfg = config.<ns>; in { … };`.
2. Add `config.flake.modules.<class>.<feature>` to the appropriate
   `imports = [ … ]` list inside `flake-modules/hosts/laptop.nix`.
3. If the feature needs host-specific values, set them as top-level
   option values in `hosts/laptop.nix`.
4. `git add` the new file (the flake build only sees git-tracked files).
5. Verify with `nix build .#nixosConfigurations.laptop.config.system.build.toplevel`
   or `nix build .#homeConfigurations.'p@laptop'.activationPackage`.

Each module begins with a short header documenting (1) why it exists
and (2) the condition under which it can be deleted.

## Adding a new host

There is no scaffolder. To add a host:

1. Create `flake-modules/hosts/<name>.nix` modeled after `laptop.nix`.
2. Generate `hosts/<name>/hardware-configuration.nix` via
   `sudo nixos-generate-config --show-hardware-config`.
3. Pick which feature modules to import; set their option values.
4. Build and switch as above.

## Module conventions

- Comment header on every module: (1) why it exists, (2) retirement
  condition.
- `lib.mkDefault` for policy values that hosts may want to override
  without `mkForce`.
- Top-level options live next to the module that owns them; consumed
  by reading `config.<ns>` inside the module that contributes the
  config.

## One-time hardware setup (laptop only)

These steps are required once after the first `nixos-rebuild switch`.

### Fingerprint reader

Enroll your fingerprints (repeat for each finger you want):

```sh
fprintd-enroll
# or enroll a specific finger:
fprintd-enroll -f right-index-finger "$USER"
```

Verify enrollment:

```sh
fprintd-verify
```

### IR face authentication (howdy)

The IR emitter needs a one-time calibration. Run this from a Wayland
terminal (not a TTY) so the preview window can open:

```sh
sudo -E linux-enable-ir-emitter configure
```

Follow the prompts — it shows a live IR camera preview and asks whether
the emitter is flashing. Select the correct emitter mode when it works.

Then enroll your face:

```sh
sudo howdy add
```

Verify face auth works:

```sh
sudo howdy test
```

After both are set up, the auth order at login/lock/sudo is:
**face → fingerprint → password** (any one is sufficient).

## Repository conventions

- Nix code is formatted with `nixpkgs-fmt` (see
  `flake-modules/formatter.nix`).
- Commit messages: short imperative subject; body for the "why".
- Line endings stay LF (enforced by `.gitattributes`).
- Substantial sessions get a note in `docs/sessions/YYYY-MM-DD-<slug>.md`.
- Past session notes are immutable.
