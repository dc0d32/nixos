{ lib, variables, ... }:
# Cursor and GTK theme are now configured in extras.nix (Catppuccin Mocha Blue).
# This file is kept as a stub so any host-level overrides can go here.
let
  cfg = variables.desktop.niri or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
}
