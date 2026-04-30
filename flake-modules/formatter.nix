# `nix fmt` — formats every .nix file in this repo with nixpkgs-fmt.
{ ... }: {
  perSystem = { pkgs, ... }: {
    formatter = pkgs.nixpkgs-fmt;
  };
}
