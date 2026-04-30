# laptop — primary dev machine (Lenovo X1 Yoga, x86_64-linux).
#
# DENDRITIC MIGRATION NOTE: this host module is currently a *bridge*
# between the new flake-parts substrate and the legacy
# ./modules/{nixos,home}/ tree. It absorbs what `lib/mkHost` and
# `lib/mkHome` used to do (read variables.nix, thread it through
# specialArgs, build a home-manager pkgs instance with overlays).
#
# As features migrate into ./flake-modules/<feature>.nix, the
# `imports` lists below shrink. When the legacy tree is empty:
#   - the `imports = [ ../../modules/nixos ];` line goes away
#   - the `imports = [ ../../modules/home ];` line goes away
#   - hosts/laptop/configuration.nix's responsibilities collapse into
#     this file
#   - hosts/laptop/variables.nix is deleted; its remaining values move
#     into option settings on the relevant feature modules below
#
# Until then, this file is intentionally a thin shim. Don't add
# feature config here — add a feature module under ./flake-modules/
# instead.
{ inputs, lib, config, ... }:
let
  hostName = "laptop";
  variables = import ../../hosts/laptop/variables.nix;
  userVariables = import (../../homes + "/p@laptop/variables.nix");

  system = variables.system or "x86_64-linux";

  hmVariables = variables // userVariables // {
    user = variables.user;
    hostname = hostName;
  };
  user = hmVariables.user;

  # HM pkgs instance. Mirrors the pre-dendritic mkHome:
  #   - apply repo-wide overlays (overlays/default.nix)
  #   - allowUnfree for chrome/vscode/etc.
  #   - allowAliases = false to silence transitive deprecation warnings
  #     (e.g. nvim-treesitter-legacy) on pinned nixos-unstable
  hmPkgs = import inputs.nixpkgs {
    inherit system;
    overlays = import ../../overlays;
    config = {
      allowUnfree = true;
      allowAliases = false;
    };
  };
in
{
  # ── Top-level option values supplied by this host ────────────────
  # Each setting here is read by a feature module under
  # ./flake-modules/<feature>.nix. See that module for the option
  # type and how it's consumed.
  host = {
    name = hostName;
    user = user;
    inherit system;
    stateVersion = hmVariables.stateVersion or "25.11";
  };

  git = {
    name = variables.git.name or variables.user or "change me";
    email = variables.git.email or "change@me.invalid";
  };

  gpu.driver = variables.gpu.driver or "none";

  locale = {
    timezone = variables.timezone;
    lang = variables.locale;
  };

  battery = {
    chargeStopThreshold = variables.battery.chargeStopThreshold;
    chargeStartThreshold = variables.battery.chargeStartThreshold;
    criticalPercent = variables.battery.criticalPercent;
    criticalAction = variables.battery.criticalAction;
    powerSaverPercent = variables.battery.powerSaverPercent;
    swapSizeGiB = variables.battery.swapSizeGiB;
    # btrfs root partition holding /swap/swapfile.
    resumeDevice = "/dev/disk/by-uuid/e2ac9790-a670-4602-ba38-6aaee856b73c";
  };

  audio = {
    preset = variables.audio.easyeffects.preset or null;
    presetsDir = variables.audio.easyeffects.presetsDir or null;
    irsDir = variables.audio.easyeffects.irsDir or null;
    autoloadDevice = variables.audio.easyeffects.autoloadDevice or null;
    autoloadDeviceProfile = variables.audio.easyeffects.autoloadDeviceProfile or "";
    autoloadDeviceDescription = variables.audio.easyeffects.autoloadDeviceDescription or "";
  };

  # ── Per-host configuration entries ───────────────────────────────
  configurations.nixos.${hostName} = {
    specialArgs.variables = variables;
    module = {
      imports = [
        ../../modules/nixos
        ../../hosts/laptop/configuration.nix
        # Migrated dendritic feature modules (NixOS side). Each entry
        # corresponds to a removed `imports` line in
        # modules/nixos/default.nix.
        config.flake.modules.nixos.hardware-hacking
        config.flake.modules.nixos.gpu
        config.flake.modules.nixos.power
        config.flake.modules.nixos.networking
        config.flake.modules.nixos.nix-settings
        config.flake.modules.nixos.system-utils
        config.flake.modules.nixos.users
        config.flake.modules.nixos.fonts
        config.flake.modules.nixos.locale
        config.flake.modules.nixos.battery
        config.flake.modules.nixos.audio
        config.flake.modules.nixos.biometrics
      ];
    };
  };

  configurations.homeManager."${user}@${hostName}" = {
    pkgs = hmPkgs;
    extraSpecialArgs.variables = hmVariables;
    module = {
      imports = [
        ../../modules/home
        (../../homes + "/p@laptop/home.nix")
        # Migrated dendritic feature modules (HM side). Each entry
        # corresponds to a removed `imports` line in
        # modules/home/default.nix.
        config.flake.modules.homeManager.git
        config.flake.modules.homeManager.tmux
        config.flake.modules.homeManager.direnv
        config.flake.modules.homeManager.fonts
        config.flake.modules.homeManager.btop
        config.flake.modules.homeManager.build-deps
        config.flake.modules.homeManager.gh
        config.flake.modules.homeManager.ai-cli
        config.flake.modules.homeManager.hardware-hacking
        config.flake.modules.homeManager.audio
      ];

      home.username = user;
      home.homeDirectory =
        if lib.hasSuffix "darwin" system
        then "/Users/${user}"
        else "/home/${user}";
      home.stateVersion = hmVariables.stateVersion or "25.11";
    };
  };
}
