{ pkgs, lib, variables, ... }:
# Polkit authentication agent.
#
# polkit (system-level) is enabled by modules/nixos/desktop/niri.nix, but
# polkit needs a USER-level agent to render auth prompts (e.g. "Authenticate
# to mount this drive", "Authenticate to unlock the Bitwarden vault"). With
# no agent running, polkit-driven auth requests silently fail under Wayland
# — there's no fallback to a controlling tty in a graphical session.
#
# We use hyprpolkitagent (Qt6/QML, lightweight, Wayland-native). Despite the
# name it works in any Wayland compositor — niri included. The autostart is
# wired through niri's spawn-at-startup so the agent is up before any app
# can issue a polkit request.
#
# Gated on desktop.niri.enable so non-desktop hosts don't pull in Qt deps.
let
  cfg = variables.desktop.niri or { enable = false; };
  enabled = cfg.enable or false;
in
lib.mkIf enabled {
  home.packages = [ pkgs.hyprpolkitagent ];

  # hyprpolkitagent ships a polkitagent binary at libexec/. Spawn it at niri
  # startup. Concatenated via mkAfter into the shared spawn-at-startup list.
  programs.niri.settings.spawn-at-startup = lib.mkAfter [
    { command = [ "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent" ]; }
  ];
}
