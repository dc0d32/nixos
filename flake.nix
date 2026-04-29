{
  description = "dc0d32 NixOS + home-manager flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

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
  };

  outputs = inputs@{ self, nixpkgs, home-manager, ... }:
    let
      mylib = import ./lib { inherit inputs; };

      hostsDir = ./hosts;
      homesDir = ./homes;
      modulesDir = ./modules;

      forAllSystems = mylib.forAllSystems;
    in
    {
      inherit mylib;

      nixosConfigurations = mylib.mkAllHosts { inherit hostsDir modulesDir; };

      homeConfigurations = mylib.mkAllHomes { inherit homesDir hostsDir modulesDir; };

      # `nix run .#new-host -- <hostname>`
      apps = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          newHost = import ./apps/new-host.nix { inherit pkgs; };
        in
        {
          new-host = {
            type = "app";
            program = "${newHost}/bin/new-host";
          };
          default = self.apps.${system}.new-host;
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [ nix nixpkgs-fmt git ];
          };
        });

      packages = forAllSystems (_: { });

      formatter = forAllSystems (system:
        (import nixpkgs { inherit system; }).nixpkgs-fmt);
    };
}
