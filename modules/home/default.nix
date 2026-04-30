{ lib, variables ? { }, ... }:
# Intentionally does NOT take `pkgs` as a module argument. Reading `pkgs` in a
# module that computes `imports` creates an infinite recursion under
# home-manager: imports are resolved before config, but `pkgs` here is not a
# specialArg — it resolves through `_module.args`, which requires `config`,
# which hasn't been evaluated yet.
#
# We use `variables.system` (a specialArg, no config needed) to decide which
# imports apply.
let
  system = variables.system or "x86_64-linux";
  isLinux = lib.hasSuffix "linux" system;
  isWsl = variables.wsl.enable or false;
  hasDesktop = isLinux && !isWsl;
in
{
  imports = [
  ] ++ lib.optionals hasDesktop [
    ./desktop/niri.nix
    ./desktop/quickshell
  ];

  programs.home-manager.enable = true;
}
