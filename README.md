# dc0d32 / nixos

Personal declarative config for NixOS (full system) and home-manager.
Configured hosts:

- `pb-x1` — primary dev laptop (Lenovo X1 Yoga gen 7, x86_64-linux).
- `wsl` — NixOS inside WSL2 on x86_64 Windows.
- `wsl-arm` — NixOS inside WSL2 on Windows on ARM (aarch64-linux).

More machines (additional laptops + servers) will be added under
`flake-modules/hosts/<name>.nix`.

## Layout

```
flake.nix                     inputs + flake-parts substrate
flake-modules/                dendritic feature modules (one per concern)
  hosts/pb-x1.nix             host bridge: primary laptop
  hosts/wsl.nix               host bridge: both WSL configurations
  <feature>.nix               each contributes flake.modules.{nixos,homeManager}.<feature>
  quickshell/qml/             QML tree deployed to ~/.config/quickshell/
  FusionLike/                 FreeCAD auto-startup mod (Init.py + InitGui.py)
hosts/pb-x1/                  hardware-configuration.nix + audio presets/IRS dirs
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
- Per-NixOS-config values (hostname, primary user, etc.) are set
  inside each host bridge's `configurations.nixos.<name>.module = { … }`
  block, NOT at the flake-parts level. See `flake-modules/users.nix`
  for the `users.primary` pattern.

Design choices:

- **Home Manager is standalone** (not wired into NixOS as a module).
- **Everything declarative**: no separate dotfiles repo. User configs
  live under `flake-modules/<feature>.nix`.
- **Compositor**: niri. **Shell**: zsh. **Editor**: neovim.
  **Terminal**: alacritty.
- **No secrets module yet** — added later if needed (sops-nix or agenix).

## Day-to-day

```sh
# Rebuild NixOS on the primary laptop
sudo nixos-rebuild switch --flake .#pb-x1

# Rebuild user environment on the primary laptop
home-manager switch --flake .#'p@pb-x1'

# Inside WSL (x86_64)
sudo nixos-rebuild switch --flake .#wsl
home-manager switch --flake .#'p@wsl'

# Inside WSL (Windows on ARM)
sudo nixos-rebuild switch --flake .#wsl-arm
home-manager switch --flake .#'p@wsl-arm'

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
   `imports = [ … ]` list inside the host bridges that should enable
   the feature (e.g. `flake-modules/hosts/pb-x1.nix`).
3. If the feature needs host-specific values, set them as top-level
   option values in the host bridge.
4. `git add` the new file (the flake build only sees git-tracked files).
5. Verify with `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
   or `nix build .#homeConfigurations.'<user>@<host>'.activationPackage`.

Each module begins with a short header documenting (1) why it exists
and (2) the condition under which it can be deleted.

## Adding a new host

There is no scaffolder. To add a host:

1. Create `flake-modules/hosts/<name>.nix` modeled after `pb-x1.nix`
   (full desktop laptop) or `wsl.nix` (headless / WSL).
2. Generate `hosts/<name>/hardware-configuration.nix` via
   `sudo nixos-generate-config --show-hardware-config`.
3. Pick which feature modules to import; set their option values.
4. Set `users.primary = "<your-user>";` inside the per-config
   `module` block (declared by `flake-modules/users.nix`).
5. Build and switch as above.

## Module conventions

- Comment header on every module: (1) why it exists, (2) retirement
  condition.
- `lib.mkDefault` for policy values that hosts may want to override
  without `mkForce`.
- Top-level options live next to the module that owns them; consumed
  by reading `config.<ns>` inside the module that contributes the
  config.
- Per-NixOS-config values (hostname, primary user, system tuple, …)
  are set inside `configurations.nixos.<name>.module`, NOT at the
  flake-parts level.

## One-time hardware setup (hosts importing `biometrics`)

These steps are required once after the first `nixos-rebuild switch`
on any laptop importing `flake-modules/biometrics.nix` (currently
pb-x1 and pb-t480). Other hosts (WSL, headless servers) don't need
any of this.

### Quick path: `biometrics-enroll`

The interactive helper walks you through both fingerprint and face
enrollment. Run from a Wayland terminal (not a TTY) so the IR
emitter calibration preview can open:

```sh
biometrics-enroll          # all of it: fingerprints, then face
biometrics-enroll fingerprint
biometrics-enroll face
biometrics-enroll verify   # test both after enrollment
```

The script invokes `sudo` internally only for the steps that need
it (IR emitter calibration, howdy).

### Manual path

If you want to drive it yourself instead of via `biometrics-enroll`:

```sh
# Fingerprints — repeat for each finger you want.
fprintd-enroll
# or enroll a specific finger:
fprintd-enroll -f right-index-finger "$USER"
fprintd-verify

# IR face: one-time calibration, then enroll a model.
# Must run from a Wayland session (not a TTY) so the preview opens.
sudo -E linux-enable-ir-emitter configure
sudo howdy -U "$USER" add
sudo howdy -U "$USER" test
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
