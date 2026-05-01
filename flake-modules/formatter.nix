# `nix fmt` — formats every .nix file in this repo with nixpkgs-fmt.
#
# Retire when: never. As long as `nix fmt` is the canonical way to
#   format the tree, a perSystem formatter binding is required. Switch
#   the package (e.g. to alejandra) in place rather than removing.
{ ... }: {
  perSystem = { pkgs, ... }: {
    formatter = pkgs.nixpkgs-fmt;
  };
}
