# dc0d32 / nixos

Personal declarative config for NixOS (full system) and macOS (home-manager only).

Layout at a glance:

```
flake.nix                   inputs + outputs, auto-discovers hosts/ and homes/
lib/                        mkHost / mkHome helpers
hosts/<hostname>/           NixOS system config (configuration.nix + variables.nix + hardware)
homes/<user>@<hostname>/    home-manager user profile (works on NixOS and macOS)
modules/nixos/              reusable system modules (niri, ly login, pipewire, gpu, power, system-utils, networking, fonts, ...)
modules/home/               reusable user modules (neovim+LSP, zsh, alacritty, btop, build-deps, niri, waybar/quickshell, idle, chrome, git, tmux, direnv)
apps/new-host.nix           `nix run .#new-host -- <hostname>` scaffolder
pkgs/ overlays/             custom packages and overlays
docs/                       design notes and AI session history (see docs/sessions/)
```

Design choices:
- **Home Manager is standalone** (not wired into NixOS). Same HM modules apply on macOS.
- **Everything declarative**: no separate dotfiles repo. Configs live under `modules/home/*`.
- **Compositor**: niri. **Shell**: zsh. **Editor**: neovim. **Terminal**: alacritty.
- **No secrets module yet** — added later if needed (sops-nix or agenix).

The full design rationale (why standalone HM instead of nix-darwin, why niri, what
Nix does to your Mac at install time, etc.) is captured in
[`docs/sessions/2026-04-21-initial-scaffold.md`](docs/sessions/2026-04-21-initial-scaffold.md).
When running Claude Code from a different machine on this repo, point it at that
file first so it inherits the context.

## Bootstrap: fresh NixOS

```sh
# From the live installer or a fresh install with `git` available
nix-shell -p git
git clone https://github.com/dc0d32/nixos ~/nixos
cd ~/nixos

# Scaffold a host entry; opens variables.nix in $EDITOR
nix run .#new-host -- "$(hostname)"

# Commit the generated host dir, then build
git add -A
sudo nixos-rebuild switch --flake .#"$(hostname)"

# (optional) activate standalone home-manager for your user
nix run home-manager/master -- switch --flake .#"$USER@$(hostname)"
```

## Bootstrap: fresh NixOS in WSL (incl. Windows on ARM)

This flake pulls the WSL module from
[`dc0d32/nixos-aarch64-wsl`](https://github.com/dc0d32/nixos-aarch64-wsl),
which publishes both x86_64-linux and aarch64-linux rootfs tarballs so
Windows on ARM works out of the box. The same flake works on x86_64 WSL.

```powershell
# 1. In Windows (PowerShell):
wsl --install --no-distribution
# Download the rootfs tarball from the fork's Releases:
#   https://github.com/dc0d32/nixos-aarch64-wsl/releases
#   pick nixos-wsl.aarch64.tar.gz on Windows-on-ARM
#   pick nixos-wsl.x86_64.tar.gz on Intel/AMD Windows
wsl --import NixOS $HOME\wsl\nixos .\nixos-wsl.<arch>.tar.gz --version 2
wsl -d NixOS
```

```sh
# 2. Inside the NixOS WSL distro:
nix-shell -p git
git clone https://github.com/dc0d32/nixos ~/nixos && cd ~/nixos

nix run .#new-host -- "$(hostname)" --wsl

git add -A
sudo nixos-rebuild switch --flake .#"$(hostname)"

# 3. Back in Windows, restart the distro so systemd picks up cleanly:
#    wsl --terminate NixOS
```

The `--wsl` flag detects ARM vs x86_64 via `uname -m`, sets
`variables.wsl.enable = true`, turns off niri/waybar/pipewire/ly/idle/chrome,
and sets `gpu.driver = "none"` (WSLg handles the GPU).

## Bootstrap: fresh macOS

```sh
# Install Nix via the Determinate installer (has a proper uninstaller,
# handles APFS volume + _nixbld users + nix-daemon launchd plist cleanly)
curl -sSf -L https://install.determinate.systems/nix | sh -s -- install

git clone https://github.com/dc0d32/nixos ~/nixos
cd ~/nixos

nix run .#new-host -- "$(hostname -s)" --mac

nix run home-manager/master -- switch --flake .#"$USER@$(hostname -s)"
```

## Day-to-day

```sh
# Rebuild NixOS
sudo nixos-rebuild switch --flake .#<hostname>

# Rebuild just the user environment (works on NixOS and macOS)
home-manager switch --flake .#<user>@<hostname>

# Update all inputs
nix flake update

# Evaluate everything without building
nix flake check

# Format all nix files
nix fmt
```

## Adding a feature

1. Drop a new file under `modules/nixos/` or `modules/home/`.
2. Gate it on a flag in `variables.nix` (e.g. `variables.foo.enable`).
3. Import it from the corresponding `default.nix`.

Host-specific packages live in `hosts/<h>/host-packages.nix`.
Host-specific user overrides live in `homes/<u>@<h>/home.nix`.

## First-time follow-ups on a new clone

After the initial scaffold commit, before a real rebuild:

1. **Produce the lockfile** on a Nix-capable machine:
   ```sh
   nix flake update
   git add flake.lock && git commit -m "flake.lock"
   ```
2. **Smoke-test evaluation**:
   ```sh
   nix flake check
   ```
3. **Push to GitHub** if not already there:
   ```sh
   gh repo create dc0d32/nixos --source . --public --push
   # or:  git remote add origin git@github.com:dc0d32/nixos.git && git push -u origin main
   ```

## One-time hardware setup (laptop only)

These steps are required once after the first `nixos-rebuild switch` on a new
machine. They configure hardware that can't be fully automated declaratively.

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

The IR emitter needs a one-time calibration. Run this from a Wayland terminal
(not a TTY) so the preview window can open:

```sh
sudo -E linux-enable-ir-emitter configure
```

Follow the prompts — it will show a live IR camera preview and ask whether the
emitter is flashing. Select the correct emitter mode when it works.

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

## Known caveats / things to watch

- **niri-flake outputs** — the module paths used in
  `modules/nixos/desktop/niri.nix` and `modules/home/desktop/niri.nix`
  (`inputs.niri.nixosModules.niri`, `inputs.niri.homeModules.niri`)
  track upstream `github:sodiboo/niri-flake`. If they rename outputs,
  update those two files.
- **Nerd Fonts rename** — recent nixpkgs moved from
  `nerdfonts.override { fonts = [...]; }` to namespaced
  `pkgs.nerd-fonts.jetbrains-mono` etc. If `nix flake check` complains
  in `modules/nixos/fonts.nix`, switch to the new naming.
- **Darwin + homeManagerConfiguration** — `home-manager.lib.homeManagerConfiguration`
  needs its `pkgs` to be built for a darwin system. `lib/default.nix :: mkHome`
  honors `variables.system`, so always scaffold a Mac host with
  `nix run .#new-host -- <name> --mac` (which sets the right system string).
- **Line endings on Windows** — `.gitattributes` forces LF on all text files.
  Nix will reject CRLF in some contexts. Don't disable this.
- **Hardware config placeholder** — `hosts/_template/hardware-configuration.nix`
  is intentionally empty so that a forgotten `nixos-generate-config` step fails
  loudly at rebuild time instead of booting a broken system.

## Repository conventions

- Nix code is formatted with `nixpkgs-fmt` (see `flake.nix :: formatter`).
- Commit messages: short imperative subject; body for the "why".
- One module per concern; each module gates on
  `variables.<ns>.<name>.enable`.
- Do not import modules globally unless they're safe to always apply
  (see `modules/nixos/default.nix` for the aggregator pattern).
