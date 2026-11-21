# The kids' maths workspace environment, as a flake of its own.
#
# Why a separate flake and not an output of the repo's root flake: direnv's
# `use flake` fetches EVERY input of the flake it is given. The root flake has
# many (microvm, disko, hardware, ...), so building a Python shell from it
# downloaded unrelated sources and failed whenever one host was unreachable.
# This flake has nixpkgs only.
#
# Used as `use flake github:dc0d32/nixos?dir=maths` from ~/src/math/.envrc
# (seeded by flake-modules/math-tools.nix). Its flake.lock is separate from the
# fleet's: after a fleet nixpkgs bump, move it onto the same revision with
#   ./scripts/sync-maths-lock.sh
# or the kids' Python stays on the old pin (harmless, just older).
#
# Retire when: the kids stop using the maths workspace.
{
  description = "Maths workspace Python environment for the kids";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      devShells = forAll (pkgs: { default = (import ./default.nix { inherit pkgs; }).shell; });
      packages = forAll (pkgs: { inherit (import ./default.nix { inherit pkgs; }) mathkit; });
    };
}
