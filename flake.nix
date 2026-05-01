{
  description = "dc0d32 NixOS + home-manager flake (dendritic substrate)";

  # Top-level flake-parts configuration. Every Nix file under
  # ./flake-modules/ is a top-level module of this configuration,
  # auto-imported by `vic/import-tree`.
  #
  # See docs/sessions/2026-04-30-dendritic-migration.md for the rationale
  # and migration plan. While the migration is in progress, legacy
  # NixOS/HM modules under ./modules/{nixos,home}/ continue to be
  # consumed by ./flake-modules/hosts/*.nix until each feature is
  # migrated into its own ./flake-modules/<feature>.nix.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    import-tree.url = "github:vic/import-tree";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # niri-flake — scrollable-tiling Wayland compositor.
    #
    # We deliberately do NOT set `inputs.nixpkgs.follows = "nixpkgs"`
    # here. niri-flake publishes prebuilt binaries to niri.cachix.org
    # keyed off ITS OWN nixpkgs pin; overriding that pin diverges every
    # closure hash from cachix and forces a local source rebuild of
    # niri (slow on weak laptops, sometimes flaky on intermittent
    # networks — observed during pb-t480 install). Letting niri keep
    # its own nixpkgs costs a slightly bigger eval-time closure but
    # gives us cache hits.
    #
    # The niri-flake NixOS module also auto-installs the cachix
    # substituter on first rebuild (see niri-flake README / opt-out via
    # `niri-flake.cache.enable = false;`). We do not opt out.
    niri.url = "github:sodiboo/niri-flake";

    # NixOS inside WSL. Use dc0d32/nixos-aarch64-wsl
    # aarch64-linux rootfs for Windows on ARM; also works fine on x86_64.
    nixos-wsl = {
      url = "github:dc0d32/nixos-aarch64-wsl";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixos-hardware — community-maintained hardware-specific NixOS
    # modules (kernel modules, firmware, sane defaults, quirks). Used
    # by laptop hosts to import their model-specific module
    # (e.g. lenovo-thinkpad-t480) instead of hand-rolling each fix.
    # Pinned to nixpkgs-follows-free release branch (no nixpkgs input
    # to override).
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # git-hooks.nix — declarative pre-commit hooks. We use it to wire
    # gitleaks (secret scanner) into every commit, since this repo is
    # public and a leaked plaintext API key would be immediately scraped
    # by GitHub's bot ecosystem. Wired from flake-modules/dev-shell.nix.
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; }
      (inputs.import-tree ./flake-modules);
}
