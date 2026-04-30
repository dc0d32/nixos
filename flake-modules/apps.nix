# `nix run .#new-host -- <hostname>` scaffolds a new host directory.
# The implementation lives in apps/new-host.nix; this module just
# wires it into flake-parts as a perSystem app.
#
# Safe to delete only by also deleting apps/new-host.nix and removing
# the docs that reference `nix run .#new-host`.
{ ... }: {
  perSystem = { pkgs, ... }:
    let
      newHost = import ../apps/new-host.nix { inherit pkgs; };
    in
    {
      apps.new-host = {
        type = "app";
        program = "${newHost}/bin/new-host";
      };
      apps.default = {
        type = "app";
        program = "${newHost}/bin/new-host";
      };
    };
}
