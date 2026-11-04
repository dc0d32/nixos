# herdr — agent-aware terminal multiplexer, trialled alongside tmux.
#
# herdr (herdr.dev) is a tmux-style multiplexer (persistent server,
# workspaces / tabs / panes, prefix key) that also detects AI coding
# agents running in panes and shows blocked / working / done state in a
# sidebar. It is being tried as a tmux replacement for agent work and
# general homelab sessions. tmux (flake-modules/tmux.nix) and psmux stay
# installed and configured; nothing here touches them.
#
# The settings are published as `flake.lib.herdrSettings` and rendered to
# TOML by BOTH this module (Linux / macOS: ~/.config/herdr/config.toml)
# and flake-modules/windows (%APPDATA%\herdr\config.toml), so the two
# can't drift. Nothing in it is OS-specific: herdr picks pwsh/$SHELL
# itself, and every key below is read identically on all platforms.
#
# How the tmux preferences map (tmux.nix is the source of truth for the
# tmux side):
#   - prefix Ctrl+b                -> herdr's default, left alone
#   - prefix h/j/k/l pane focus    -> herdr's default, left alone
#   - prefix H/J/K/L resize        -> bound explicitly (below); herdr also
#                                     has a repeatable resize mode, prefix r
#   - prefix | and -  to split     -> `|` added next to herdr's `v`; `-` is
#                                     already herdr's default
#   - new panes keep the cwd       -> herdr's default (`new_cwd = "follow"`)
#   - `c` makes a window at once   -> `prompt_new_tab_name = false`
#   - colour39 accent, muted bar   -> herdr's Nord theme (matching the niri
#                                     desktop), and a status area on the tab
#                                     row carrying host + date/time
#   - 100k lines of history        -> herdr's 10 MB/pane default is about
#                                     the same; not overridden
# Not carried over: tmux's `prefix r` reload (herdr uses `prefix r` for
# resize mode; reload stays on its default `prefix+shift+r`).
#
# The config is a read-only Nix store symlink, so herdr's in-app settings
# screen cannot write to it. `onboarding = false` is set for the same
# reason — onboarding would try to write that flag back. Run
# `herdr integration` once per machine to opt in to the per-agent hooks
# that give the sidebar exact state; that writes into each agent's own
# config, not herdr's.
#
# Retire when: herdr is dropped from the daily workflow (tmux stays), or
#   it replaces tmux on every host and the two configs are merged.
let
  settings = {
    # Skip first-run onboarding: it persists its answer by rewriting
    # config.toml, which is read-only here.
    onboarding = false;

    # Nord, herdr's built-in: the same palette as the niri desktop
    # (waybar #2e3440 / #eceff4 / accent #88c0d0, mako border #4c566a), so
    # the multiplexer reads as part of the desktop. Hand-picking tokens
    # would only reproduce what this theme already ships.
    theme.name = "nord";

    # The binary is Nix/Scoop managed; `herdr update` is not the update
    # path, so don't phone home to nag about versions.
    update.version_check = false;

    keys = {
      # tmux muscle memory: prefix | splits side by side. `v` stays too.
      split_vertical = [ "prefix+|" "prefix+v" ];

      # tmux's prefix H/J/K/L resize. Not auto-repeating like `bind -r`;
      # for held resizing use herdr's resize mode (prefix r).
      resize_pane_left = "prefix+shift+h";
      resize_pane_down = "prefix+shift+j";
      resize_pane_up = "prefix+shift+k";
      resize_pane_right = "prefix+shift+l";
    };

    ui = {
      # Agent state by glyph shape as well as colour, so blocked vs working
      # stays legible through remote-desktop colour compression — the same
      # reason the tmux bar uses one bright pill instead of many colours.
      status_indicators = "symbols";

      # tmux `c` opens a window straight away; don't ask for a name first.
      prompt_new_tab_name = false;

      # Name the agent in each pane's border, so a split view says which
      # agent is which without opening the sidebar.
      show_agent_labels_on_pane_borders = true;

      # Right edge of the tab row, mirroring the tmux bar's right side:
      # (zoom marker when zoomed) · machine · date and time. The icons are
      # core Font Awesome glyphs (server, clock), present in every Nerd Font
      # — the same set the tmux bar draws from. The entries themselves
      # cannot be coloured, so the icons are what carries the style.
      tab_bar_right = [
        { type = "zoom"; }
        { type = "text"; text = ""; }
        { type = "hostname"; }
        { type = "text"; text = ""; }
        { type = "datetime"; format = "%a %d %b %H:%M"; }
      ];
      tab_bar_right_separator = " ";

      # Sidebar rows, in Nord's frost tones: machine (only shown when more
      # than one is connected) in teal, workspace in bold, the agent's name
      # in muted blue. Same rows as herdr's defaults, just styled.
      sidebar.agents.rows = [
        [
          "state_icon"
          { token = "machine"; fg = "#8fbcbb"; }
          { token = "workspace"; bold = true; }
          "tab"
        ]
        [{ token = "agent"; fg = "#81a1c1"; }]
      ];
      sidebar.spaces.rows = [
        [ "state_icon" { token = "workspace"; bold = true; } ]
        [{ token = "branch"; fg = "#81a1c1"; } "git_status"]
      ];

      # Agents finishing / needing input in a background workspace is the
      # main reason to run this; surface it in-app. Sound stays off: it is
      # no use on headless or remote-desktop hosts and a nuisance elsewhere.
      toast.delivery = "herdr";
      sound.enabled = false;
    };
  };
in
{
  flake.lib.herdrSettings = settings;

  flake.modules.homeManager.herdr = { pkgs, lib, config, ... }: {
    home.packages = [ pkgs.herdr ];

    # Agent integrations (session ids + authoritative state in the sidebar).
    # `herdr integration install` refuses to run unless the agent's config
    # dir exists, so: install where the dir exists; for copilot/opencode
    # also where the agent is on PATH but has never run (create the dir the
    # agent would). Hermes needs one run first, to not disturb its first-run
    # bootstrap. Idempotent; failures warn and never fail the switch.
    # Re-running refreshes the hooks after a herdr bump. Windows twin:
    # setup.ps1 in flake-modules/windows/windows.nix.
    home.activation.herdrIntegrations = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      herdr=${pkgs.herdr}/bin/herdr
      status="$($herdr integration status 2>/dev/null || true)"
      herdr_integrate() {
        local name="$1" dir="$2" create="$3"
        if printf '%s\n' "$status" | grep -q "^$name: current"; then
          return 0
        fi
        if [ ! -d "$dir" ]; then
          if [ "$create" = 1 ] && command -v "$name" >/dev/null 2>&1; then
            mkdir -p "$dir"
          else
            return 0
          fi
        fi
        $herdr integration install "$name" >/dev/null \
          || echo "warning: herdr integration install $name failed" >&2
      }
      herdr_integrate copilot "''${COPILOT_HOME:-${config.home.homeDirectory}/.copilot}" 1
      herdr_integrate opencode "${config.home.homeDirectory}/.config/opencode" 1
      herdr_integrate hermes "''${HERMES_HOME:-${config.home.homeDirectory}/.hermes}" 0
    '';

    xdg.configFile."herdr/config.toml".source =
      (pkgs.formats.toml { }).generate "herdr-config.toml" settings;
  };
}
