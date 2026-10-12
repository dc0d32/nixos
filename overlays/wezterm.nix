# Recent WezTerm fixes need one locked source revision on Linux and macOS.
# Retire when nixpkgs provides an equally recent revision and native app packaging.
{ src }:
final: prev:
{
  wezterm = import ./wezterm-source.nix { inherit src; } final prev;
}
