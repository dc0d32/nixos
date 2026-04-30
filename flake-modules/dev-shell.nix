# Default devShell for hacking on this flake itself.
#
# Provides nix tooling and git. Editor / language tools are not added
# here — they belong in the user's home-manager config.
{ ... }: {
  perSystem = { pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [ nix nixpkgs-fmt git ];
    };
  };
}
