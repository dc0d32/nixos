# Polkit user-side authentication agent.
#
# polkit (system-level) is enabled by flake-modules/niri.nix, but
# polkit needs a USER-level agent to render auth prompts (e.g.
# "Authenticate to mount this drive", "Authenticate to unlock the
# Bitwarden vault"). With no agent running, polkit-driven auth
# requests silently fail under Wayland — there's no fallback to a
# controlling tty in a graphical session.
#
# We use hyprpolkitagent (Qt6/QML, lightweight, Wayland-native).
# Despite the name it works in any Wayland compositor — niri
# included. The autostart is wired through niri's spawn-at-startup
# so the agent is up before any app can issue a polkit request.
#
# Pattern A: hosts opt in by importing this module. Tied to the
# niri user session because spawn-at-startup is a niri-specific
# option; non-desktop hosts simply don't import this.
#
# Retire when: niri is replaced by a compositor that ships its own
#   polkit agent (e.g. KDE/GNOME), OR hyprpolkitagent is superseded by
#   a maintained Wayland-native alternative we'd rather use.
{ ... }:
{
  flake.modules.homeManager.polkit-agent = { pkgs, lib, ... }: {
    home.packages = [ pkgs.hyprpolkitagent ];

    # hyprpolkitagent ships a polkitagent binary at libexec/. Spawn
    # it at niri startup. mkOrder 1490 places it just before the
    # default mkAfter slot (1500) used by quickshell, so the polkit
    # agent is up first regardless of which order the calling host
    # bridge listed the imports in.
    programs.niri.settings.spawn-at-startup = lib.mkOrder 1490 [
      { command = [ "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent" ]; }
    ];
  };
}
