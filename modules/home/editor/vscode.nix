{ pkgs, lib, variables, ... }:
let
  cfg = variables.apps.vscode or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
    mutableExtensionsDir = true;
  };
}
