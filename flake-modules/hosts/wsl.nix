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
# Note on the top-level `host` option: this module deliberately does
# NOT set `host = { ... }`. The `host.user` value is set once by the
# laptop bridge (and is identical across hosts in this repo). The
# `host.{name,system,stateVersion}` fields are declared but currently
# unread by any feature module; per-host name/system/stateVersion are
# captured locally below and used directly in each per-config block.
#
# Rebuild from inside WSL:
#   sudo nixos-rebuild switch --flake .#wsl       # x86_64 Windows
#   sudo nixos-rebuild switch --flake .#wsl-arm   # Windows on ARM
#   home-manager switch --flake .#'p@wsl'         # or 'p@wsl-arm'
{ inputs, config, ... }:
let
  user = "p";
  stateVersion = "25.11";

  # Per-arch pkgs instance, with repo-wide overlays applied. Memoised
  # via `let` so each system is imported once even though both NixOS
  # and HM sides reference it.
  mkPkgs = system: import inputs.nixpkgs {
    inherit system;
    overlays = import ../../overlays;
    config = {
      allowUnfree = true;
      allowAliases = false;
    };
  };

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
    ];

    # WSL has no hardware-configuration.nix to set the platform for
    # us; do it here.
    nixpkgs.hostPlatform = system;
    networking.hostName = name;

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
  # p@wsl-arm. NOT importing the GUI-only modules (alacritty,
  # desktop-extras, wallpaper, idle, freecad, niri, quickshell,
  # vscode, chrome, bitwarden, polkit-agent, audio, fonts, hardware-hacking).
  hmModule = {
    imports = [
      config.flake.modules.homeManager.git
      config.flake.modules.homeManager.tmux
      config.flake.modules.homeManager.direnv
      config.flake.modules.homeManager.btop
      config.flake.modules.homeManager.build-deps
      config.flake.modules.homeManager.gh
      config.flake.modules.homeManager.ai-cli
      config.flake.modules.homeManager.zsh
      config.flake.modules.homeManager.neovim
    ];

    programs.home-manager.enable = true;

    home.sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
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
