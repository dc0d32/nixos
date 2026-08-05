# niri keybindings — extracted from niri.nix on 2026-06-25 to keep each
# niri concern in its own file (the binds table is the single largest
# section of the niri config). Contributes to the SAME merged HM module
# `flake.modules.homeManager.niri` as niri.nix and window-rules.nix via
# the flake-parts deferredModule merge, so the split is purely
# organizational — the rendered config is identical.
#
# `hotkey-overlay.title` does DOUBLE duty since 2026-08-04. It is
# (1) the human-readable label niri's own overlay shows for a bind, and
# (2) the curation marker read by flake-modules/discovery.nix: a bind
# appears in the generated `guide` cheat sheet iff it has a title. Both
# read the same attribute, so the cheat sheet cannot drift from reality.
#
# Practical consequences when editing this file:
#   * Give a title to any bind worth telling a human about. Leave the
#     ~100 mechanical navigation variants untitled — they stay reachable
#     via Mod+Shift+Slash without burying the useful entries.
#   * Binds sharing one title are collapsed onto a single row in the
#     guide, so give the arrow-key and the vim-key form of the same
#     action the SAME title (`Mod+Left` and `Mod+H` → one row).
#   * Titles are read by kids. Write "Close this window", not
#     "close-window".
#
# Retire when: niri.nix as a whole is retired (see its header), OR the
#   binds table shrinks enough that inlining it back is no longer noise.
{
  flake.modules.homeManager.niri = { config, options, inputs, lib, pkgs, ... }: {
    programs.niri.settings.binds = {
      "Mod+Shift+Slash" = {
        hotkey-overlay.title = "Show every keyboard shortcut (this list)";
        action.show-hotkey-overlay = { };
      };

      "Mod+T" = {
        hotkey-overlay.title = "Open a terminal";
        action.spawn = "alacritty";
      };
      # GUI file manager — Thunar. yazi is still installed via
      # desktop-extras and remains usable from any terminal; this
      # keybind just prefers the GUI for casual file browsing
      # (USB-stick mounting via gvfs+udisks2, drag-and-drop, etc.).
      "Mod+E" = {
        hotkey-overlay.title = "Open the file manager (USB sticks, phones, zips)";
        action.spawn = "thunar";
      };
      # App launcher — fuzzel (wired in flake-modules/desktop-shell.nix).
      "Super+Space" = {
        hotkey-overlay.title = "Find and launch an app";
        action.spawn = "fuzzel";
      };

      # Lockscreen — swaylock-effects (wired in flake-modules/
      # lockscreen.nix), driven via logind. `loginctl lock-session`
      # emits the logind Lock signal, which swayidle (flake-modules/
      # idle.nix) handles by running the single-instance lock wrapper —
      # so a manual lock and an idle lock share one code path and never
      # stack. Returns immediately; niri stays responsive.
      "Super+Alt+L" = {
        hotkey-overlay.title = "Lock the screen";
        action.spawn = [ "loginctl" "lock-session" ];
      };

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
        hotkey-overlay.title = "Show all your windows and workspaces at once";
        action.toggle-overview = { };
      };

      "Mod+Q" = {
        repeat = false;
        hotkey-overlay.title = "Close this window";
        action.close-window = { };
      };

      "Mod+Left" = {
        hotkey-overlay.title = "Focus the window to the left";
        action.focus-column-left = { };
      };
      "Mod+Down" = {
        hotkey-overlay.title = "Focus the window below";
        action.focus-window-down = { };
      };
      "Mod+Up" = {
        hotkey-overlay.title = "Focus the window above";
        action.focus-window-up = { };
      };
      "Mod+Right" = {
        hotkey-overlay.title = "Focus the window to the right";
        action.focus-column-right = { };
      };
      "Mod+H" = {
        hotkey-overlay.title = "Focus the window to the left";
        action.focus-column-left = { };
      };
      "Mod+J" = {
        hotkey-overlay.title = "Focus the window below";
        action.focus-window-down = { };
      };
      "Mod+K" = {
        hotkey-overlay.title = "Focus the window above";
        action.focus-window-up = { };
      };
      "Mod+L" = {
        hotkey-overlay.title = "Focus the window to the right";
        action.focus-column-right = { };
      };

      "Mod+Ctrl+Left" = {
        hotkey-overlay.title = "Move this window left";
        action.move-column-left = { };
      };
      "Mod+Ctrl+Down" = {
        hotkey-overlay.title = "Move this window down";
        action.move-window-down = { };
      };
      "Mod+Ctrl+Up" = {
        hotkey-overlay.title = "Move this window up";
        action.move-window-up = { };
      };
      "Mod+Ctrl+Right" = {
        hotkey-overlay.title = "Move this window right";
        action.move-column-right = { };
      };
      "Mod+Ctrl+H" = {
        hotkey-overlay.title = "Move this window left";
        action.move-column-left = { };
      };
      "Mod+Ctrl+J" = {
        hotkey-overlay.title = "Move this window down";
        action.move-window-down = { };
      };
      "Mod+Ctrl+K" = {
        hotkey-overlay.title = "Move this window up";
        action.move-window-up = { };
      };
      "Mod+Ctrl+L" = {
        hotkey-overlay.title = "Move this window right";
        action.move-column-right = { };
      };

      "Mod+Home".action.focus-column-first = { };
      "Mod+End".action.focus-column-last = { };
      "Mod+Ctrl+Home".action.move-column-to-first = { };
      "Mod+Ctrl+End".action.move-column-to-last = { };

      "Mod+Shift+Left" = {
        hotkey-overlay.title = "Jump to the screen on the left";
        action.focus-monitor-left = { };
      };
      "Mod+Shift+Down".action.focus-monitor-down = { };
      "Mod+Shift+Up".action.focus-monitor-up = { };
      "Mod+Shift+Right" = {
        hotkey-overlay.title = "Jump to the screen on the right";
        action.focus-monitor-right = { };
      };
      "Mod+Shift+H" = {
        hotkey-overlay.title = "Jump to the screen on the left";
        action.focus-monitor-left = { };
      };
      "Mod+Shift+J".action.focus-monitor-down = { };
      "Mod+Shift+K".action.focus-monitor-up = { };
      "Mod+Shift+L" = {
        hotkey-overlay.title = "Jump to the screen on the right";
        action.focus-monitor-right = { };
      };

      "Mod+Shift+Ctrl+Left".action.move-column-to-monitor-left = { };
      "Mod+Shift+Ctrl+Down".action.move-column-to-monitor-down = { };
      "Mod+Shift+Ctrl+Up".action.move-column-to-monitor-up = { };
      "Mod+Shift+Ctrl+Right".action.move-column-to-monitor-right = { };
      "Mod+Shift+Ctrl+H".action.move-column-to-monitor-left = { };
      "Mod+Shift+Ctrl+J".action.move-column-to-monitor-down = { };
      "Mod+Shift+Ctrl+K".action.move-column-to-monitor-up = { };
      "Mod+Shift+Ctrl+L".action.move-column-to-monitor-right = { };

      "Mod+Page_Down" = {
        hotkey-overlay.title = "Go to the next workspace down";
        action.focus-workspace-down = { };
      };
      "Mod+Page_Up" = {
        hotkey-overlay.title = "Go to the next workspace up";
        action.focus-workspace-up = { };
      };
      "Mod+U" = {
        hotkey-overlay.title = "Go to the next workspace down";
        action.focus-workspace-down = { };
      };
      "Mod+I" = {
        hotkey-overlay.title = "Go to the next workspace up";
        action.focus-workspace-up = { };
      };
      "Mod+Ctrl+Page_Down" = {
        hotkey-overlay.title = "Take this window to the workspace below";
        action.move-column-to-workspace-down = { };
      };
      "Mod+Ctrl+Page_Up" = {
        hotkey-overlay.title = "Take this window to the workspace above";
        action.move-column-to-workspace-up = { };
      };
      "Mod+Ctrl+U" = {
        hotkey-overlay.title = "Take this window to the workspace below";
        action.move-column-to-workspace-down = { };
      };
      "Mod+Ctrl+I" = {
        hotkey-overlay.title = "Take this window to the workspace above";
        action.move-column-to-workspace-up = { };
      };

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

      "Mod+1" = {
        hotkey-overlay.title = "Jump straight to a workspace (Mod+1 … Mod+9)";
        action.focus-workspace = 1;
      };
      "Mod+2".action.focus-workspace = 2;
      "Mod+3".action.focus-workspace = 3;
      "Mod+4".action.focus-workspace = 4;
      "Mod+5".action.focus-workspace = 5;
      "Mod+6".action.focus-workspace = 6;
      "Mod+7".action.focus-workspace = 7;
      "Mod+8".action.focus-workspace = 8;
      "Mod+9".action.focus-workspace = 9;
      "Mod+Ctrl+1" = {
        hotkey-overlay.title = "Send this window to a workspace (Mod+Ctrl+1 … 9)";
        action.move-column-to-workspace = 1;
      };
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

      "Mod+Comma" = {
        hotkey-overlay.title = "Pull the next window into this column";
        action.consume-window-into-column = { };
      };
      "Mod+Period" = {
        hotkey-overlay.title = "Push this window out into its own column";
        action.expel-window-from-column = { };
      };

      "Mod+R" = {
        hotkey-overlay.title = "Cycle this window through preset widths";
        action.switch-preset-column-width = { };
      };
      "Mod+Shift+R".action.switch-preset-column-width-back = { };

      "Mod+Ctrl+Shift+R".action.switch-preset-window-height = { };
      "Mod+Ctrl+R".action.reset-window-height = { };

      "Mod+F" = {
        hotkey-overlay.title = "Make this window fill the screen width";
        action.maximize-column = { };
      };
      "Mod+Shift+F" = {
        hotkey-overlay.title = "Fullscreen this window";
        action.fullscreen-window = { };
      };

      "Mod+Ctrl+F".action.expand-column-to-available-width = { };

      "Mod+C" = {
        hotkey-overlay.title = "Centre this window on screen";
        action.center-column = { };
      };

      "Mod+Ctrl+C".action.center-visible-columns = { };

      "Mod+Minus" = {
        hotkey-overlay.title = "Make this window narrower";
        action.set-column-width = "-10%";
      };
      "Mod+Equal" = {
        hotkey-overlay.title = "Make this window wider";
        action.set-column-width = "+10%";
      };

      "Mod+Shift+Minus".action.set-window-height = "-10%";
      "Mod+Shift+Equal".action.set-window-height = "+10%";

      "Mod+V" = {
        hotkey-overlay.title = "Let this window float freely";
        action.toggle-window-floating = { };
      };
      "Mod+Shift+V" = {
        hotkey-overlay.title = "Switch between floating and tiled windows";
        action.switch-focus-between-floating-and-tiling = { };
      };

      "Mod+W" = {
        hotkey-overlay.title = "Stack this column into tabs";
        action.toggle-column-tabbed-display = { };
      };

      # Screenshots — `screenshot` helper from desktop-shell.nix
      # wraps grim + slurp + satty (region picker → annotation).
      # Print       = region picker → satty annotation
      # Shift+Print = whole-screen → satty annotation
      # Alt+Print   = focused window (niri native)
      "Print" = {
        hotkey-overlay.title = "Screenshot part of the screen, then draw on it";
        action.spawn = [ "screenshot" "region" ];
      };
      "Shift+Print" = {
        hotkey-overlay.title = "Screenshot the whole screen, then draw on it";
        action.spawn = [ "screenshot" "screen" ];
      };
      "Alt+Print" = {
        hotkey-overlay.title = "Screenshot just this window";
        action.screenshot-window = { };
      };

      # Clipboard history — fuzzel dmenu picker over cliphist
      # (`clipboard-pick` helper from desktop-shell.nix).
      "Mod+Shift+C" = {
        hotkey-overlay.title = "Paste something you copied earlier (clipboard history)";
        action.spawn = "clipboard-pick";
      };

      # Screen recording — toggle wf-recorder for full screen capture
      # First invocation starts recording to ~/Videos/; second sends SIGINT to stop.
      "Mod+Ctrl+Shift+S" = {
        hotkey-overlay.title = "Start / stop recording the screen as a video";
        action.spawn = [
          "bash"
          "-c"
          "if pgrep -x wf-recorder > /dev/null; then pkill -INT wf-recorder; else mkdir -p ~/Videos && wf-recorder -f ~/Videos/recording.mp4; fi"
        ];
      };

      "Mod+Escape" = {
        allow-inhibiting = false;
        hotkey-overlay.title = "Log out";
        action.spawn = "loginctl terminate-user $USER";
      };

      "Mod+Shift+E".action.quit = { };
      "Ctrl+Alt+Delete".action.quit = { };

      "Mod+Shift+P" = {
        hotkey-overlay.title = "Turn the screens off";
        action.power-off-monitors = { };
      };

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
  };
}
