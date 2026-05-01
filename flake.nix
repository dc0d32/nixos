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

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NixOS inside WSL. Use dc0d32/nixos-aarch64-wsl
    # aarch64-linux rootfs for Windows on ARM; also works fine on x86_64.
    nixos-wsl = {
      url = "github:dc0d32/nixos-aarch64-wsl";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sops-nix — declarative secret decryption at activation time, both
    # NixOS-scope (/run/secrets) and home-manager-scope
    # (~/.config/sops-nix/secrets). Wired from flake-modules/secrets.nix.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # git-hooks.nix — declarative pre-commit hooks. We use it to wire
    # gitleaks (secret scanner) into every commit, since this repo is
    # public and a leaked plaintext API key / age private key would be
    # immediately scraped by GitHub's bot ecosystem. Wired from
    # flake-modules/dev-shell.nix.
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; }
      (inputs.import-tree ./flake-modules);
}
