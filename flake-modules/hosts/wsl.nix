# wsl + wsl-arm — NixOS inside WSL2.
#
# Single dendritic host module that produces TWO NixOS configurations
# (`wsl`, `wsl-arm`) and TWO home-manager configurations
# (`p@wsl`, `p@wsl-arm`) from one shared body. The two differ only in
# `name` and `system` (and therefore `nixpkgs.hostPlatform`).
#
# Why one file and not two:
#   - The bodies were 95% identical (same imports, same package set,
#     same skipped feature modules); duplicating them invites drift.
#   - Pure flake-parts: a single host module is allowed to declare
#     multiple `configurations.nixos.<name>` entries.
#
# Why not Option B (one `wsl` config picking `system` from
# `builtins.currentSystem`):
#   - That requires `--impure` for every build, breaks `nix flake
#     check`, and prevents cross-architecture evaluation.
#
# Note: this module deliberately does NOT set any top-level
# (flake-parts level) host metadata options. Per-host values like the
# hostname, primary user, and system tuple are conceptually per-NixOS-
# config; they live inside each per-config `module = { ... }` block
# below. The `users.primary` option declared by flake-modules/users.nix
# is set per-config the same way.
#
# Rebuild from inside WSL:
#   sudo nixos-rebuild switch --flake .#wsl       # x86_64 Windows
#   sudo nixos-rebuild switch --flake .#wsl-arm   # Windows on ARM
#   home-manager switch --flake .#'p@wsl'         # or 'p@wsl-arm'
#
# Retire when: both WSL distros are decommissioned (no Windows host
#   needs a NixOS-in-WSL environment), OR the x86_64/aarch64 split
#   collapses to a single arch and one of the two configs is dropped.
{ config, ... }:
let
  user = "p";
  stateVersion = "25.11";

  # Per-arch pkgs instance, supplied by the shared factory in
  # ../mk-pkgs.nix. Both NixOS and HM sides reference this.
  mkPkgs = config.flake.lib.mkPkgs;

  # NixOS module shared by both wsl and wsl-arm. Headless WSL only —
  # NOT importing: gpu, power, networking (NetworkManager), battery,
  # audio, biometrics, login-ly, niri, fonts.
  mkNixosModule = { name, system }: { pkgs, ... }: {
    imports = [
      # WSL glue — first so its mkForce overrides win against any
      # baseline default brought in by a shared module.
      config.flake.modules.nixos.wsl

      config.flake.modules.nixos.nix-settings
      config.flake.modules.nixos.system-utils
      config.flake.modules.nixos.users
      config.flake.modules.nixos.locale
      # Auto-bootstraps p's home-manager profile on first boot. WSL
      # systemd is somewhat constrained, but oneshot multi-user.target
      # services run fine.
      config.flake.modules.nixos.home-manager-bootstrap
    ];

    # WSL has no hardware-configuration.nix to set the platform for
    # us; do it here.
    nixpkgs.hostPlatform = system;
    networking.hostName = name;
    users.primary = user;

    # Skip explicit users.users.${user}: the WSL fork creates the
    # default user itself. Shell is forced to zsh by
    # flake-modules/wsl.nix.

    # Tiny system package set; rest lives in home-manager.
    environment.systemPackages = with pkgs; [
      git
      vim
      curl
      wget
    ];

    system.stateVersion = stateVersion;
  };

  # Headless-friendly home-manager module shared by p@wsl and
  # p@wsl-arm. Uses the `dev` bundle (= base CLI tools + ai-cli +
  # build-deps); GUI/desktop modules are intentionally excluded.
  hmModule = {
    imports = config.flake.lib.bundles.homeManager.dev;

    programs.home-manager.enable = true;

    home.sessionVariables = {
      EDITOR = "vim";
      VISUAL = "vim";
    };

    home.username = user;
    home.homeDirectory = "/home/${user}";
    home.stateVersion = stateVersion;
  };

  hosts = [
    { name = "wsl"; system = "x86_64-linux"; }
    { name = "wsl-arm"; system = "aarch64-linux"; }
  ];
in
{
  # Shared per-feature-module options that this host wants to override.
  # Both WSL hosts share these values, so set them once at the top level.
  git = {
    name = "CHANGEME";
    email = "CHANGEME@example.com";
  };

  locale = {
    timezone = "America/Los_Angeles";
    lang = "en_US.UTF-8";
  };

  # NixOS configurations — one per (name, system) pair.
  configurations.nixos = builtins.listToAttrs (map
    ({ name, system }: {
      inherit name;
      value.module = mkNixosModule { inherit name system; };
    })
    hosts);

  # Home-manager configurations — one per host, named "${user}@${name}".
  configurations.homeManager = builtins.listToAttrs (map
    ({ name, system }: {
      name = "${user}@${name}";
      value = {
        pkgs = mkPkgs system;
        module = hmModule;
      };
    })
    hosts);
}
