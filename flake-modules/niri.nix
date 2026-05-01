# niri — scrollable-tiling Wayland compositor (cross-class).
#
# NixOS class:
#   - enables programs.niri, pulls in companion CLI tools
#   - wires xdg-portal to the gtk + wlr backends
#   - brings up dbus + polkit + power-profiles-daemon + upower
#   - disables the niri-flake polkit agent so our hyprpolkitagent
#     (HM-side) doesn't race with it
#
# homeManager class:
#   - imports inputs.niri.homeModules.niri
#   - the user-side niri config (the kdl file, keybinds, layout)
#
# App launcher, clipboard history, and screenshot picker were native fuzzel /
# cliphist+fuzzel / grim+slurp+satty bash one-liners; they are now native
# Quickshell overlays driven by IPC (`quickshell ipc call <target> toggle`).
# See flake-modules/quickshell/qml/{launcher,clipboard,screenshot}/.
#
# Pattern A: hosts opt in by importing this module. Headless / WSL
# hosts simply don't import it, so inputs.niri's modules are never
# imported either — desktops that don't run niri don't pay the eval
# cost.
#
# Migrated from modules/nixos/desktop/niri.nix and
# modules/home/desktop/niri.nix. Keybinds and window-rules carried
# over verbatim.
#
# Retire when: the user switches Wayland compositor (hyprland, sway,
# etc.) or niri grows to the size of warranting a dedicated subtree.
{ ... }:
{
  flake.modules.nixos.niri = { inputs, lib, pkgs, ... }: {
    imports = [ inputs.niri.nixosModules.niri ];

    programs.niri.enable = true;

    # Useful companions
    environment.systemPackages = with pkgs; [
      wl-clipboard
      wlr-randr
      brightnessctl
      playerctl
      grim
      slurp
      mako
      xdg-utils
    ];

    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
        xdg-desktop-portal-wlr # screenshare/screencast for wlroots compositors
      ];
      # Without an explicit config, xdg-desktop-portal matches
      # backends by UseIn= in *.portal files. Both gtk.portal and
      # gnome.portal declare UseIn=gnome, which is wrong for niri
      # and causes gnome-portal to be activated alongside (or
      # instead of) gtk-portal, leading to startup races and timeout
      # failures. Pin niri to the gtk backend explicitly, using wlr
      # for screencast.
      config.niri = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
      };
    };

    services.dbus.enable = true;
    security.polkit.enable = true;
    services.power-profiles-daemon.enable = lib.mkDefault true;

    # UPower daemon — provides org.freedesktop.UPower over system
    # dbus, which quickshell's Quickshell.Services.UPower
    # (BatteryState.qml) consumes for battery percentage / charging
    # state. Without this, only the power-profiles-daemon-provided
    # org.freedesktop.UPower.PowerProfiles interface is on the bus,
    # and BatteryState.present stays false → the battery chip is
    # hidden. Safe to leave on for desktops without a battery
    # (UPower simply reports no laptop battery and BatteryState
    # hides itself).
    services.upower.enable = lib.mkDefault true;

    # niri-flake auto-installs polkit-kde-authentication-agent-1 as
    # a user systemd unit (niri-flake-polkit.service,
    # WantedBy=niri.service). We already run hyprpolkitagent
    # ourselves (see flake-modules/polkit-agent.nix); two
    # agents racing on the same dbus subject yields
    #   "Cannot register authentication agent: ... agent already
    #    exists for the given subject"
    # and the loser flaps until systemd's restart counter trips,
    # leaving the user session degraded. Disable the niri-flake
    # one. Documented opt-out per niri-flake README.
    systemd.user.services.niri-flake-polkit.enable = false;
  };

  flake.modules.homeManager.niri = { inputs, lib, pkgs, ... }: {
    imports = [ inputs.niri.homeModules.niri ];

    # ── Wayland session env propagation ─────────────────────────
    # niri does not natively push WAYLAND_DISPLAY / XDG_CURRENT_DESKTOP
    # into the user systemd manager or D-Bus activation environment.
    # Without this, every user systemd unit that needs a Wayland
    # connection (awww-daemon, easyeffects, anything graphical-
    # session.target-bound) starts before the env is set, fails to
    # connect to the compositor, and crashes — typically with
    # "WAYLAND_DISPLAY is not set" or socket-not-found errors.
    #
    # The canonical fix (per niri-flake README, sway/hyprland conventions)
    # is to run dbus-update-activation-environment with --systemd at
    # session start; this single call:
    #   1. registers the listed env vars with the user D-Bus daemon so
    #      D-Bus-activated services see them, and
    #   2. propagates them into `systemctl --user` via systemd's own
    #      env-import mechanism.
    # graphical-session.target then has the right env when its wanted
    # services start.
    #
    # Variables propagated: WAYLAND_DISPLAY (the obvious one),
    # XDG_CURRENT_DESKTOP (used by xdg-portal backend selection,
    # gtk theming, and the per-compositor branches in many apps).
    #
    # mkBefore so this env-propagation runs FIRST, before all the
    # other spawn-at-startup entries (bitwarden, polkit-agent,
    # easyeffects, quickshell) — those depend on the env having
    # been pushed.
    #
    # Retire when: niri grows native systemd-import behaviour at
    # session start (tracked in niri upstream; not present as of 25.08).
    programs.niri.settings.spawn-at-startup = lib.mkBefore [
      {
        command = [
          "${pkgs.dbus}/bin/dbus-update-activation-environment"
          "--systemd"
          "WAYLAND_DISPLAY"
          "XDG_CURRENT_DESKTOP"
        ];
      }
    ];

    programs.niri.settings = {
      input.keyboard = {
        xkb.layout = "us";
        repeat-delay = 200;
        repeat-rate = 35;
      };
      input.touchpad = {
        tap = true;
        natural-scroll = true;
        accel-profile = "flat";
        # Slow scrolling — default 1.0 was way too fast on this trackpad;
        # Niri scales libinput scroll deltas by this factor for
        # both touchpad axes.
        scroll-factor = 0.4;
      };
      input.mouse = {
        accel-profile = "flat";
      };
      prefer-no-csd = true;
      hotkey-overlay = {
        skip-at-startup = true;
      };
      outputs = {
        "eDP-1" = {
          scale = 1;
        };
      };
      layout = {
        gaps = 2;
        border.width = 2;
      };
      binds = {
        "Mod+Shift+Slash".action.show-hotkey-overlay = { };

        "Mod+T".action.spawn = "alacritty";
        "Mod+E".action.spawn = [ "alacritty" "-e" "yazi" ];
        # App launcher — quickshell native overlay (replaces fuzzel).
        "Super+Space".action.spawn = [
          "bash"
          "-c"
          "${pkgs.quickshell}/bin/quickshell ipc --pid $(pgrep -o quickshell) call launcher toggle"
        ];

        "Super+Alt+L".action.spawn = [ "bash" "-c" "${pkgs.quickshell}/bin/quickshell ipc --pid $(pgrep -o quickshell) call lock lock" ];

        "XF86AudioRaiseVolume" = {
          allow-when-locked = true;
          action.spawn = [ "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.025+" "-l" "1.0" ];
        };
        "XF86AudioLowerVolume" = {
          allow-when-locked = true;
          action.spawn = [ "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.025-" ];
        };
        "XF86AudioMute" = {
          allow-when-locked = true;
          action.spawn = [ "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle" ];
        };

        "XF86AudioPlay" = {
          allow-when-locked = true;
          action.spawn = "playerctl play-pause";
        };
        "XF86AudioNext" = {
          allow-when-locked = true;
          action.spawn = "playerctl next";
        };
        "XF86AudioPrev" = {
          allow-when-locked = true;
          action.spawn = "playerctl previous";
        };

        "XF86MonBrightnessUp" = {
          allow-when-locked = true;
          action.spawn = [ "brightnessctl" "--class=backlight" "set" "+5%" ];
        };
        "XF86MonBrightnessDown" = {
          allow-when-locked = true;
          action.spawn = [ "brightnessctl" "--class=backlight" "set" "5%-" ];
        };

        "Mod+O" = {
          repeat = false;
          action.toggle-overview = { };
        };

        "Mod+Q" = {
          repeat = false;
          action.close-window = { };
        };

        "Mod+Left".action.focus-column-left = { };
        "Mod+Down".action.focus-window-down = { };
        "Mod+Up".action.focus-window-up = { };
        "Mod+Right".action.focus-column-right = { };
        "Mod+H".action.focus-column-left = { };
        "Mod+J".action.focus-window-down = { };
        "Mod+K".action.focus-window-up = { };
        "Mod+L".action.focus-column-right = { };

        "Mod+Ctrl+Left".action.move-column-left = { };
        "Mod+Ctrl+Down".action.move-window-down = { };
        "Mod+Ctrl+Up".action.move-window-up = { };
        "Mod+Ctrl+Right".action.move-column-right = { };
        "Mod+Ctrl+H".action.move-column-left = { };
        "Mod+Ctrl+J".action.move-window-down = { };
        "Mod+Ctrl+K".action.move-window-up = { };
        "Mod+Ctrl+L".action.move-column-right = { };

        "Mod+Home".action.focus-column-first = { };
        "Mod+End".action.focus-column-last = { };
        "Mod+Ctrl+Home".action.move-column-to-first = { };
        "Mod+Ctrl+End".action.move-column-to-last = { };

        "Mod+Shift+Left".action.focus-monitor-left = { };
        "Mod+Shift+Down".action.focus-monitor-down = { };
        "Mod+Shift+Up".action.focus-monitor-up = { };
        "Mod+Shift+Right".action.focus-monitor-right = { };
        "Mod+Shift+H".action.focus-monitor-left = { };
        "Mod+Shift+J".action.focus-monitor-down = { };
        "Mod+Shift+K".action.focus-monitor-up = { };
        "Mod+Shift+L".action.focus-monitor-right = { };

        "Mod+Shift+Ctrl+Left".action.move-column-to-monitor-left = { };
        "Mod+Shift+Ctrl+Down".action.move-column-to-monitor-down = { };
        "Mod+Shift+Ctrl+Up".action.move-column-to-monitor-up = { };
        "Mod+Shift+Ctrl+Right".action.move-column-to-monitor-right = { };
        "Mod+Shift+Ctrl+H".action.move-column-to-monitor-left = { };
        "Mod+Shift+Ctrl+J".action.move-column-to-monitor-down = { };
        "Mod+Shift+Ctrl+K".action.move-column-to-monitor-up = { };
        "Mod+Shift+Ctrl+L".action.move-column-to-monitor-right = { };

        "Mod+Page_Down".action.focus-workspace-down = { };
        "Mod+Page_Up".action.focus-workspace-up = { };
        "Mod+U".action.focus-workspace-down = { };
        "Mod+I".action.focus-workspace-up = { };
        "Mod+Ctrl+Page_Down".action.move-column-to-workspace-down = { };
        "Mod+Ctrl+Page_Up".action.move-column-to-workspace-up = { };
        "Mod+Ctrl+U".action.move-column-to-workspace-down = { };
        "Mod+Ctrl+I".action.move-column-to-workspace-up = { };

        "Mod+Shift+Page_Down".action.move-workspace-down = { };
        "Mod+Shift+Page_Up".action.move-workspace-up = { };
        "Mod+Shift+U".action.move-workspace-down = { };
        "Mod+Shift+I".action.move-workspace-up = { };

        "Mod+WheelScrollDown" = {
          cooldown-ms = 150;
          action.focus-workspace-down = { };
        };
        "Mod+WheelScrollUp" = {
          cooldown-ms = 150;
          action.focus-workspace-up = { };
        };
        "Mod+Ctrl+WheelScrollDown" = {
          cooldown-ms = 150;
          action.move-column-to-workspace-down = { };
        };
        "Mod+Ctrl+WheelScrollUp" = {
          cooldown-ms = 150;
          action.move-column-to-workspace-up = { };
        };

        "Mod+WheelScrollRight".action.focus-column-right = { };
        "Mod+WheelScrollLeft".action.focus-column-left = { };
        "Mod+Ctrl+WheelScrollRight".action.move-column-right = { };
        "Mod+Ctrl+WheelScrollLeft".action.move-column-left = { };

        "Mod+Shift+WheelScrollDown".action.focus-column-right = { };
        "Mod+Shift+WheelScrollUp".action.focus-column-left = { };
        "Mod+Ctrl+Shift+WheelScrollDown".action.move-column-right = { };
        "Mod+Ctrl+Shift+WheelScrollUp".action.move-column-left = { };

        "Mod+1".action.focus-workspace = 1;
        "Mod+2".action.focus-workspace = 2;
        "Mod+3".action.focus-workspace = 3;
        "Mod+4".action.focus-workspace = 4;
        "Mod+5".action.focus-workspace = 5;
        "Mod+6".action.focus-workspace = 6;
        "Mod+7".action.focus-workspace = 7;
        "Mod+8".action.focus-workspace = 8;
        "Mod+9".action.focus-workspace = 9;
        "Mod+Ctrl+1".action.move-column-to-workspace = 1;
        "Mod+Ctrl+2".action.move-column-to-workspace = 2;
        "Mod+Ctrl+3".action.move-column-to-workspace = 3;
        "Mod+Ctrl+4".action.move-column-to-workspace = 4;
        "Mod+Ctrl+5".action.move-column-to-workspace = 5;
        "Mod+Ctrl+6".action.move-column-to-workspace = 6;
        "Mod+Ctrl+7".action.move-column-to-workspace = 7;
        "Mod+Ctrl+8".action.move-column-to-workspace = 8;
        "Mod+Ctrl+9".action.move-column-to-workspace = 9;

        "Mod+BracketLeft".action.consume-or-expel-window-left = { };
        "Mod+BracketRight".action.consume-or-expel-window-right = { };

        "Mod+Comma".action.consume-window-into-column = { };
        "Mod+Period".action.expel-window-from-column = { };

        "Mod+R".action.switch-preset-column-width = { };
        "Mod+Shift+R".action.switch-preset-column-width-back = { };

        "Mod+Ctrl+Shift+R".action.switch-preset-window-height = { };
        "Mod+Ctrl+R".action.reset-window-height = { };

        "Mod+F".action.maximize-column = { };
        "Mod+Shift+F".action.fullscreen-window = { };

        "Mod+Ctrl+F".action.expand-column-to-available-width = { };

        "Mod+C".action.center-column = { };

        "Mod+Ctrl+C".action.center-visible-columns = { };

        "Mod+Minus".action.set-column-width = "-10%";
        "Mod+Equal".action.set-column-width = "+10%";

        "Mod+Shift+Minus".action.set-window-height = "-10%";
        "Mod+Shift+Equal".action.set-window-height = "+10%";

        "Mod+V".action.toggle-window-floating = { };
        "Mod+Shift+V".action.switch-focus-between-floating-and-tiling = { };

        "Mod+W".action.toggle-column-tabbed-display = { };

        # Screenshots — quickshell overlay drives grim/slurp/satty.
        # Print       = picker (region/screen/region-clipboard) → satty annotation
        # Alt+Print   = focused window (niri native, needs compositor cooperation)
        "Print".action.spawn = [
          "bash"
          "-c"
          "${pkgs.quickshell}/bin/quickshell ipc --pid $(pgrep -o quickshell) call screenshot toggle"
        ];
        "Alt+Print".action.screenshot-window = { };

        # Clipboard history — quickshell native overlay (replaces fuzzel dmenu).
        "Mod+Shift+C".action.spawn = [
          "bash"
          "-c"
          "${pkgs.quickshell}/bin/quickshell ipc --pid $(pgrep -o quickshell) call clipboard toggle"
        ];

        # Screen recording — toggle wf-recorder for full screen capture
        # First invocation starts recording to ~/Videos/; second sends SIGINT to stop.
        "Mod+Ctrl+Shift+S".action.spawn = [
          "bash"
          "-c"
          "if pgrep -x wf-recorder > /dev/null; then pkill -INT wf-recorder; else mkdir -p ~/Videos && wf-recorder -f ~/Videos/recording.mp4; fi"
        ];

        "Mod+Escape" = {
          allow-inhibiting = false;
          action.spawn = "loginctl terminate-user $USER";
        };

        "Mod+Shift+E".action.quit = { };
        "Ctrl+Alt+Delete".action.quit = { };

        "Mod+Shift+P".action.power-off-monitors = { };

        # Bring Chrome's PiP window to the current workspace. Niri has no
        # "sticky / always-on-all-workspaces" concept, so PiP lives on the
        # workspace where it spawned (per the window-rule below). This
        # binding is the manual "follow me here" — finds the PiP window
        # by title and moves it to whatever workspace is focused. Uses
        # niri-msg JSON so we don't have to parse the human-readable
        # output. Silently no-ops if no PiP window is open.
        #
        # Match by title alone: Chrome's PiP window has an empty app_id
        # on Wayland.
        #
        # `move-window-to-workspace` takes a workspace REFERENCE (index
        # or name), not a literal "focused" \u2014 so we resolve the focused
        # workspace's idx first via a second niri-msg call.
        "Mod+P" = {
          hotkey-overlay.title = "Bring Chrome PiP here";
          action.spawn = [
            "sh"
            "-c"
            ''
              id=$(${pkgs.niri}/bin/niri msg --json windows \
                | ${pkgs.jq}/bin/jq -r '.[] | select(.title=="Picture in picture") | .id' \
                | head -n1)
              ws=$(${pkgs.niri}/bin/niri msg --json workspaces \
                | ${pkgs.jq}/bin/jq -r '.[] | select(.is_focused==true) | .idx')
              if [ -n "$id" ] && [ -n "$ws" ]; then
                ${pkgs.niri}/bin/niri msg action move-window-to-workspace --window-id "$id" "$ws"
              fi
            ''
          ];
        };
      };

      window-rules = [
        # Uniform 4px rounded corners on every window. Niri's
        # window-rule property `geometry-corner-radius` takes per-corner
        # values (no shorthand in the niri-flake Nix schema), so we set
        # all four explicitly. No `matches` key = applies to every
        # window; later rules can override per-window if ever needed.
        {
          geometry-corner-radius = {
            top-left = 4.0;
            top-right = 4.0;
            bottom-right = 4.0;
            bottom-left = 4.0;
          };
        }

        {
          matches = [{ is-focused = false; }];
          opacity = 0.9;
        }

        # Chrome Picture-in-Picture window. Niri has no across-workspace
        # sticky window support (only layer-shell surfaces persist on
        # workspace switch), so the best we can do per-workspace is:
        #   1. open it floating (so it sits above tiled windows),
        #   2. anchor to the top-right corner with a small gap,
        #   3. give it a sensible default size (480x270 = 16:9 thumbnail).
        # Use Mod+P (defined above) to teleport an existing PiP to the
        # currently-focused workspace when you've moved away. Matches both
        # classic HTMLVideoElement PiP and the newer Document PiP API
        # (YouTube Miniplayer, Discord, Meet) — Chrome titles both
        # exactly "Picture in picture" on Wayland.
        #
        # Match on title only: Chrome's PiP window has an EMPTY app-id on
        # Wayland (verified via `niri msg --json windows`). Anchored to
        # ^…$ so we don't accidentally match a tab title that happens to
        # contain the words.
        {
          matches = [{
            title = "^Picture in picture$";
          }];
          open-floating = true;
          default-floating-position = {
            x = 32;
            y = 32;
            relative-to = "top-right";
          };
          default-column-width = { fixed = 480; };
          default-window-height = { fixed = 270; };
          # Don't steal focus from whatever you were doing when you hit the
          # video's PiP button.
          open-focused = false;
          # Slight transparency so the PiP doesn't fully obscure whatever
          # is underneath. Combined with the global is-focused=false rule
          # above (opacity 0.9), an unfocused PiP renders at 0.9 * 0.8 =
          # 0.72; focused PiP stays at 0.8.
          opacity = 0.8;
        }
      ];
    };
  };
}
