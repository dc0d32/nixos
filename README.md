# dc0d32 / nixos

Personal declarative config for NixOS (full system) and macOS (home-manager only).

Layout at a glance:

```
flake.nix                   inputs + outputs, auto-discovers hosts/ and homes/
lib/                        mkHost / mkHome helpers
hosts/<hostname>/           NixOS system config (configuration.nix + variables.nix + hardware)
homes/<user>@<hostname>/    home-manager user profile (works on NixOS and macOS)
modules/nixos/              reusable system modules (niri, pipewire, networking, fonts, ...)
modules/home/               reusable user modules (zsh, neovim, alacritty, niri, waybar, git, tmux, direnv)
apps/new-host.nix           `nix run .#new-host -- <hostname>` scaffolder
pkgs/ overlays/             custom packages and overlays
```

Design choices:
- **Home Manager is standalone** (not wired into NixOS). Same HM modules apply on macOS.
- **Everything declarative**: no separate dotfiles repo. Configs live under `modules/home/*`.
- **Compositor**: niri. **Shell**: zsh. **Editor**: neovim. **Terminal**: alacritty.
- **No secrets module yet** — added later if needed (sops-nix or agenix).

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

## Bootstrap: fresh macOS

```sh
# Install Nix via the Determinate installer (has a proper uninstaller)
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
```

## Adding a feature

1. Drop a new file under `modules/nixos/` or `modules/home/`.
2. Gate it on a flag in `variables.nix` (e.g. `variables.foo.enable`).
3. Import it from the corresponding `default.nix`.

Host-specific packages live in `hosts/<h>/host-packages.nix`.
Host-specific user overrides live in `homes/<u>@<h>/home.nix`.
