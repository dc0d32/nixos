# Desktop shell — bar (waybar), notifications (mako), launcher (fuzzel),
# clipboard history (cliphist + fuzzel picker), screenshot pipeline
# (grim + slurp + satty).
#
# Replaces the quickshell QML stack with mature, well-maintained
# off-the-shelf components. Sheds ~5k LOC of custom QML at the cost
# of: no unified IPC overlay flyouts, no custom power/bluetooth/media
# panes. Trade was accepted at "honest retreat" time — see the session
# log for that day.
#
# HM-only module; companion lockscreen lives in
# flake-modules/lockscreen.nix (split because it carries NixOS-side
# PAM wiring).
#
# Pattern A: hosts opt in via the home-desktop / home-kid bundle.
# waybar and mako autostart via their HM-provided systemd-user
# units; cliphist's watchers are wired here as a pair of systemd-user
# units (one per text / image MIME type, matching upstream cliphist
# recipe).
#
# Retire when: you go back to a custom shell (quickshell, ags, eww),
# or move to a compositor with its own batteries (gnome/kde).
{ ... }:
{
  flake.modules.homeManager.desktop-shell = { lib, pkgs, ... }: {
    # ── Bar ─────────────────────────────────────────────────────────
    # waybar 0.10+ ships native niri/workspaces + niri/window modules
    # talking to niri-msg IPC. Falls back to wlr/workspaces (via
    # niri's wlr-foreign-toplevel implementation) if the niri module
    # ever breaks at upstream.
    programs.waybar = {
      enable = true;
      systemd.enable = true;
      settings.mainBar = {
        layer = "top";
        position = "top";
        height = 28;
        spacing = 4;
        modules-left = [ "niri/workspaces" "niri/window" ];
        modules-center = [ "clock" ];
        modules-right = [
          "custom/help"
          "tray"
          "bluetooth"
          "network"
          "pulseaudio"
          "backlight"
          "battery"
        ];
        # Opens the discovery guide (flake-modules/discovery.nix).
        # Defined HERE rather than contributed from discovery.nix because
        # `programs.waybar.settings` is `types.anything`, whose merge
        # function does NOT concatenate lists — two modules both defining
        # `modules-right` is an eval error, not a merge. `guide` is
        # resolved from PATH: waybar spawns it without a terminal, and the
        # wrapper re-execs itself inside alacritty when it notices.
        # Degrades to a no-op button if discovery isn't imported.
        "custom/help" = {
          format = "<span size='x-large'>󰋗</span>";
          tooltip = true;
          tooltip-format = "Help & Tips — what this machine can do";
          on-click = "guide";
        };
        "niri/workspaces" = { format = "{value}"; };
        "niri/window" = {
          max-length = 60;
          separate-outputs = true;
        };
        clock = {
          format = "{:%a %d %b  %H:%M}";
          tooltip-format = "<tt><big>{calendar}</big></tt>";
        };
        battery = {
          states = {
            warning = 30;
            critical = 15;
          };
          # MD battery glyphs (same icon family + size as wifi/brightness
          # below) enlarged via a pango span so the icon is clearly a
          # battery at a glance; number stays normal size.
          format = "{capacity}% <span size='x-large'>{icon}</span>";
          format-charging = "{capacity}% <span size='x-large'>󰂄</span>";
          format-icons = [ "󰁺" "󰁼" "󰁾" "󰂀" "󰁹" ];
        };
        network = {
          # Signal shown as wifi bars (format-icons is selected by
          # signalStrength 0-100), not a bare "%", so it reads as wifi
          # at a glance. Click opens nmtui to pick/manage networks.
          format-wifi = "{essid} <span size='x-large'>{icon}</span>";
          format-ethernet = "<span size='x-large'>󰈁</span> {ifname}";
          format-disconnected = "<span size='x-large'>󰤮</span>";
          format-icons = [ "󰤯" "󰤟" "󰤢" "󰤥" "󰤨" ];
          tooltip-format = "{ifname}: {ipaddr}";
          tooltip-format-wifi = "{essid} ({signalStrength}%)\n{ifname}: {ipaddr}";
          on-click = "${pkgs.alacritty}/bin/alacritty --title nmtui -e ${pkgs.networkmanager}/bin/nmtui";
        };
        bluetooth = {
          format-on = "";
          format-off = "";
          format-connected = "{num_connections} ";
          tooltip-format = ''
            {controller_alias}	{controller_address}
            {num_connections} connected'';
          on-click = "${pkgs.blueman}/bin/blueman-manager";
        };
        pulseaudio = {
          format = "{volume}% {icon}";
          format-muted = "🔇";
          format-icons.default = [ "🔈" "🔉" "🔊" ];
          on-click = "${pkgs.pwvucontrol}/bin/pwvucontrol";
        };
        backlight = {
          # Brightness icon (sun) so the number reads as brightness at a
          # glance; the glyph fills as the level rises and is enlarged via
          # a pango span. Scroll to adjust.
          format = "{percent}% <span size='x-large'>{icon}</span>";
          format-icons = [ "󰃞" "󰃟" "󰃠" ];
          on-scroll-up = "${pkgs.brightnessctl}/bin/brightnessctl set +5%";
          on-scroll-down = "${pkgs.brightnessctl}/bin/brightnessctl set 5%-";
        };
        tray = { spacing = 8; };
      };
      style = ''
        * {
          font-family: "FantasqueSansM Nerd Font", monospace;
          font-size: 13px;
          min-height: 0;
        }
        window#waybar {
          background: rgba(46, 52, 64, 0.85);
          color: #eceff4;
        }
        #workspaces button {
          padding: 0 6px;
          color: #d8dee9;
          background: transparent;
          border: none;
          border-radius: 0;
        }
        #workspaces button.focused {
          color: #88c0d0;
          box-shadow: inset 0 -2px #88c0d0;
        }
        #clock,
        #battery,
        #network,
        #pulseaudio,
        #backlight,
        #bluetooth,
        #custom-help,
        #tray,
        #window {
          padding: 0 8px;
        }
        #custom-help { color: #88c0d0; }
        #battery.warning { color: #ebcb8b; }
        #battery.critical { color: #bf616a; }
      '';
    };

    # ── Notifications ───────────────────────────────────────────────
    services.mako = {
      enable = true;
      settings = {
        default-timeout = 8000;
        border-radius = 6;
        border-size = 1;
        background-color = "#2e3440f0";
        text-color = "#eceff4";
        border-color = "#4c566a";
      };
    };

    # ── App launcher ────────────────────────────────────────────────
    # Bound to Super+Space in niri.nix (was: quickshell IPC).
    programs.fuzzel = {
      enable = true;
      settings = {
        main = {
          terminal = "alacritty";
          layer = "overlay";
          width = 50;
          font = "monospace:size=7";
          line-height = 11;
        };
        colors = {
          background = "2e3440ee";
          text = "eceff4ff";
          selection = "88c0d0ff";
          selection-text = "2e3440ff";
          border = "88c0d0ff";
        };
        border = {
          radius = 8;
          width = 1;
        };
      };
    };

    # ── Wrappers + screenshot/clipboard helpers ─────────────────────
    # `clipboard-pick` is bound to Mod+Shift+C in niri.nix; it pops a
    # fuzzel dmenu over the cliphist history and pipes the choice back
    # to the clipboard. `screenshot region` / `screenshot screen` are
    # bound to Print / variants.
    home.packages = with pkgs; [
      cliphist
      wl-clipboard
      grim
      slurp
      satty
      (writeShellApplication {
        name = "clipboard-pick";
        runtimeInputs = [ cliphist fuzzel wl-clipboard ];
        text = ''
          choice=$(cliphist list | fuzzel --dmenu)
          [ -n "$choice" ] || exit 0
          printf '%s' "$choice" | cliphist decode | wl-copy
        '';
      })
      (writeShellApplication {
        name = "screenshot";
        runtimeInputs = [ grim slurp satty coreutils ];
        text = ''
          mode="''${1:-region}"
          out="$HOME/Pictures/screenshots/$(date +%F-%H%M%S).png"
          mkdir -p "$(dirname "$out")"
          case "$mode" in
            region) grim -g "$(slurp)" - | satty --filename - --output-filename "$out" ;;
            screen) grim - | satty --filename - --output-filename "$out" ;;
            *) echo "usage: screenshot [region|screen]" >&2 ; exit 2 ;;
          esac
        '';
      })
    ];

    # ── Clipboard history watchers ─────────────────────────────────
    # cliphist needs a wl-paste watcher per MIME type. Two systemd
    # user units — text and image. Both bound to graphical-session.
    # target so they tear down on session exit.
    systemd.user.services.cliphist-text = {
      Unit = {
        Description = "Wayland clipboard history watcher (cliphist, text)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.cliphist-image = {
      Unit = {
        Description = "Wayland clipboard history watcher (cliphist, image)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
