# niri window-rules — extracted from niri.nix on 2026-06-25 to keep each
# niri concern in its own file. Contributes to the SAME merged HM module
# `flake.modules.homeManager.niri` as niri.nix and binds.nix via the
# flake-parts deferredModule merge, so the split is purely organizational
# — the rendered config is identical.
#
# Retire when: niri.nix as a whole is retired (see its header).
{
  flake.modules.homeManager.niri = { config, options, inputs, lib, pkgs, ... }: {
    programs.niri.settings.window-rules =
      let
        # Apps that paint their entire content area opaque
        # (Chromium-family, VS Code/Electron, Firefox, …). These
        # are excluded from the focused/unfocused opacity rules
        # below — niri's `opacity` is applied to the whole
        # compositor surface, so on opaque-painting apps it just
        # produces a washed-out, low-contrast blend with whatever
        # is underneath (compounded by the global blur, which
        # makes the bleed-through wallpaper blurry too — kills
        # contrast even further). Excluded apps render at full
        # opacity in both focus states; they still get the global
        # blur via the catch-all window-rule (visible at the
        # rounded-corner cutout, where their alpha is 0). Match
        # patterns are anchored regexes against Wayland app-id
        # (xdg-shell `set_app_id`); discover an app's id at
        # runtime with `niri msg --json windows | jq '.[].app_id'`.
        excludeOpaqueApps = [
          # Firefox (Wayland-native)
          { app-id = "^firefox$"; }
          { app-id = "^org\\.mozilla\\.firefox$"; }
        ];
      in
      [
        # Catch-all window defaults: rounded corners + don't fill
        # the window area with the focus-ring/border background.
        #
        # Why `draw-border-with-background false` is the default:
        # we use the global `prefer-no-csd` setting to ask apps
        # to omit their client-side decorations, which means niri
        # would otherwise paint the focus ring as a SOLID
        # colored rectangle filling the entire window area
        # (the "background" mode). For opaque apps that's
        # invisible (their pixels cover it); for translucent
        # rules (alacritty, VS Code, Chrome, PiP) that solid
        # backdrop occludes the wallpaper / live-composite blur
        # and makes the window look gray instead of frosted.
        # Disabling it globally means the focus ring/border
        # always draws as a thin frame around the window only.
        # CSD apps already default to `false`, so this is a
        # no-op for them.
        #
        # Niri's window-rule property `geometry-corner-radius`
        # takes per-corner values (no shorthand in the niri-flake
        # Nix schema), so we set all four explicitly. No
        # `matches` key = applies to every window; later rules
        # can override per-window if ever needed.
        {
          geometry-corner-radius = {
            top-left = 4.0;
            top-right = 4.0;
            bottom-right = 4.0;
            bottom-left = 4.0;
          };
          draw-border-with-background = false;
        }

        # Per-window opacity rules. Two rules — focused vs.
        # unfocused — both with the same `excludes` clause that
        # carves out apps which paint their entire content area
        # opaque. niri's `opacity` is applied to the whole
        # compositor surface, so on opaque-painting apps it just
        # produces a washed-out, low-contrast blend with whatever
        # is underneath (compounded by the global blur, which
        # makes the bleed-through wallpaper blurry too — kills
        # contrast even further). Excluded apps render at full
        # opacity in both focus states; they still get the
        # global blur via the catch-all window-rule (visible at
        # the rounded-corner cutout, where their alpha is 0).
        #
        # Apps that intentionally have transparent regions (or
        # that we want translucent for visual effect, like
        # alacritty's macOS-style frosted-glass look) are NOT
        # excluded, so the focused/unfocused opacity dim applies
        # on top of any built-in transparency and the catch-all
        # blur shows through cleanly behind them. Alacritty has
        # an additional explicit per-app rule below that
        # overrides the catch-all 0.7 with 0.85, picked to match
        # the macOS Terminal "Pro"/"Basic" profile feel.
        #
        # Resulting opacity matrix (niri's per-window-rule opacity
        # is last-match-wins, not multiplicative):
        #   focused alacritty:                          0.85
        #   unfocused alacritty:                        0.85
        #   focused VS Code:                            0.85
        #   unfocused VS Code:                          0.85
        #   focused Chrome/Chromium:                    0.85
        #   unfocused Chrome/Chromium:                  0.85
        #   any other translucent app (none currently): 0.7
        #   any opaque app (Firefox/...):               1.0 (focused or not)
        #   PiP (rule below):                           0.6
        # (Both is-focused rules currently use the same value;
        # they're kept as separate rules so each can be tuned
        # independently later.)
        #
        # Add new opaque-painting apps to `excludeOpaqueApps`
        # below. Use `niri msg --json windows | jq '.[].app_id'`
        # to discover an app's id at runtime.
        #
        # Retire when: niri grows a per-app or per-surface
        # "blur-only, don't tint" mode (currently impossible —
        # opacity and background-effect are independent fields
        # but opacity always applies to the whole surface).
        {
          matches = [{ is-focused = false; }];
          excludes = excludeOpaqueApps;
          opacity = 0.7;
        }
        {
          matches = [{ is-focused = true; }];
          excludes = excludeOpaqueApps;
          opacity = 0.7;
        }

        # macOS-style frosted-glass terminal. Alacritty paints
        # opaque, so the only way to get see-through is at the
        # compositor level. We override the catch-all 0.7 with
        # 0.85 (close to the macOS Terminal default) in both
        # focus states so the look is consistent whether the
        # terminal is active or not — that's the "macOS feel"
        # asked for here. The catch-all blur window-rule (below)
        # then samples + blurs the wallpaper behind it for the
        # frosted-glass effect. The catch-all rule above already
        # disables `draw-border-with-background`, which is what
        # keeps the focus ring from filling the window area
        # with a solid backdrop and occluding the blur.
        {
          matches = [{ app-id = "^Alacritty$"; }];
          opacity = 0.85;
        }

        # Same macOS-style frosted-glass treatment for VS Code.
        # The Electron surface is opaque so niri's per-window
        # opacity does the work. VS Code is denser than a
        # terminal so 0.85 sits closer to the readability
        # threshold — bump up if code becomes hard to read.
        # Three matchers cover the variants seen in the wild:
        # `code` (system VS Code), `code-url-handler` (deep-link
        # invocations), `Code` (some Insiders/OSS builds).
        {
          matches = [
            { app-id = "^code$"; }
            { app-id = "^code-url-handler$"; }
            { app-id = "^Code$"; }
          ];
          opacity = 0.85;
        }

        # Chromium family - same macOS-style frosted-glass
        # treatment. Chrome paints opaque so niri's per-window
        # opacity does the work. White web pages will render
        # with visible wallpaper bleed-through behind them; if
        # that becomes annoying for a specific reading session,
        # switch to an `is-focused=false` matcher only.
        {
          matches = [
            { app-id = "^google-chrome$"; }
            { app-id = "^chromium-browser$"; }
            { app-id = "^chromium$"; }
          ];
          opacity = 0.85;
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
          # Slight transparency so the PiP doesn't fully obscure
          # whatever is underneath. niri rule opacity is
          # last-match-wins, so this 0.6 overrides the global
          # 0.7 catch-all in both focus states.
          opacity = 0.6;
        }
      ];
  };
}
