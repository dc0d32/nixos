# dc0d32 / nixos

Personal declarative config for NixOS (full system) and macOS (home-manager only).

Layout at a glance:

```
flake.nix                   inputs + outputs, auto-discovers hosts/ and homes/
lib/                        mkHost / mkHome helpers
hosts/<hostname>/           NixOS system config (configuration.nix + variables.nix + hardware)
homes/<user>@<hostname>/    home-manager user profile (works on NixOS and macOS)
modules/nixos/              reusable system modules (niri, pipewire, networking, fonts, ...)
modules/home/               reusable user modules (zsh, neovim, alacritty, niri, waybar/quickshell, git, tmux, direnv)
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
