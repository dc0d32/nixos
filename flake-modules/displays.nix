# Display / monitor layout management (niri outputs + wdisplays).
#
# WHY THIS EXISTS
# ---------------
# Before this module the entire display configuration in the flake was:
#
#     outputs = { "eDP-1" = { scale = 1; }; };     # niri.nix
#
# i.e. nothing at all for external monitors. Plugging in a dock left
# niri to guess: enable at preferred mode, guess scale from DPI, and
# append the new screen to the right in connector order. Nothing
# remembered a layout between plug events, and there was no way to
# correct it without editing Nix and rebuilding — which on pb-t480 the
# kid accounts cannot do at all. That is the other half of the "dock
# experience is pathetic" complaint (the first half being that
# DisplayLink video didn't come up at all; see displaylink.nix).
#
# THE MIDDLE GROUND
# -----------------
# Two layers, because neither alone is good enough:
#
#   1. DECLARATIVE (this module's `displays.outputs` option) — the
#      known-good layout for a host, in Nix, reviewable and in git.
#   2. MUTABLE (`~/.config/niri/outputs.local.kdl`) — what you get when
#      you drag monitors around in wdisplays and press save. No rebuild,
#      no sudo, works for non-wheel users.
#
# Layer 2 wins over layer 1 while it exists, and `display-reset` throws
# it away to fall back to the declarative layout. `display-export`
# prints the current arrangement as a Nix snippet so a good ad-hoc
# layout can be promoted into the host bridge and committed.
#
# WHY NOT kanshi
# --------------
# The usual Wayland answer to per-dock profiles is kanshi. It is not
# needed here: niri matches `output` blocks by connector name *or* by
# "MAKE MODEL SERIAL" and re-applies all output config from scratch on
# every hotplug. That is kanshi's whole feature set, built into the
# compositor. Adding kanshi would mean a second daemon fighting niri
# over the same wlr-output-management protocol.
#
# ORDERING TRAP — the mutable include must come FIRST
# ---------------------------------------------------
# niri's docs say includes are "positional. They will override options
# set prior to them", which reads as last-wins. That is TRUE for merged
# sections but FALSE for `output`, which the docs class as a "multipart
# section ... inserted as is without merging". Output lookup is
# `self.0.iter().find(|o| name.matches(&o.name))` (niri-config/src/
# output.rs:150) — a linear scan returning the FIRST match.
#
# Verified empirically against niri 2026-07-08 with two configs
# differing only in include order:
#
#     include "local.kdl"; include "base.kdl";   ->  scale 3  (local)
#     include "base.kdl";  include "local.kdl";  ->  scale 1  (base)
#
# So the mutable file is included BEFORE the generated output blocks.
# Get this backwards and saved layouts are silently ignored — the file
# is written, no error appears anywhere, and nothing changes. The
# include itself lives in niri.nix (which owns `programs.niri.config`),
# gated on the `displays.enable` signal this module publishes.
#
# RETIREMENT CONDITION
# --------------------
# Delete this file when either:
#   * niri gains a built-in "persist output layout" feature (i.e. it
#     writes back its own config on wlr-output-management changes),
#     making the save/reset scripts redundant; OR
#   * the compositor changes and display layout moves to whatever the
#     replacement uses.
{ config, lib, ... }:
let
  cfg = config.displays;

  transformType = lib.types.enum [
    "normal"
    "90"
    "180"
    "270"
    "flipped"
    "flipped-90"
    "flipped-180"
    "flipped-270"
  ];

  outputOpts = { name, ... }: {
    options = {
      off = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Disable this output entirely. Useful for a clamshell setup
          where the laptop panel should stay dark while docked.
        '';
      };

      mode = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "2560x1440@143.912";
        description = ''
          Resolution and refresh rate as `WIDTHxHEIGHT` or
          `WIDTHxHEIGHT@REFRESH`. The refresh rate must match what
          `niri msg outputs` reports to three decimal places, exactly.
          Null lets niri pick the preferred mode.
        '';
      };

      scale = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.int lib.types.float);
        default = null;
        example = 1.5;
        description = ''
          Fractional UI scale. Null lets niri guess from the monitor's
          physical size and resolution, which is usually right for
          laptop panels and usually wrong for large 4K desktop
          monitors.
        '';
      };

      position = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            x = lib.mkOption { type = lib.types.int; };
            y = lib.mkOption { type = lib.types.int; };
          };
        });
        default = null;
        example = { x = 1920; y = 0; };
        description = ''
          Position of this output's top-left corner in the global
          logical coordinate space. Null appends the output to the
          right of the others in connector order.

          Note these are LOGICAL coordinates, i.e. after scaling: a
          3840x2160 monitor at scale 2 occupies 1920x1080 of space.
        '';
      };

      transform = lib.mkOption {
        type = lib.types.nullOr transformType;
        default = null;
        example = "90";
        description = "Rotation / flip. Null means `normal`.";
      };

      variable-refresh-rate = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "on" "on-demand" ]);
        default = null;
        description = ''
          Enable VRR / adaptive sync. "on-demand" only engages it for
          fullscreen windows that ask. Null leaves VRR off.
        '';
      };

      focus-at-startup = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Focus this output when the session starts.";
      };
    };
  };
in
{
  # Cross-module signal only. The per-output layout itself is declared
  # as an option INSIDE the home-manager module below, not here:
  # flake-parts top-level options are shared across every host in the
  # flake, so a top-level `displays.outputs` set for pb-x1 would also
  # apply to pb-t480 and m-pc. Same reasoning as
  # hardware-hacking.extraUsers — see that module's header.
  #
  # NOTE this signal is currently always true in practice: import-tree
  # loads every file under flake-modules/, so this file is always a
  # flake-parts module and the `config.displays.enable = true` below
  # always applies. It is NOT a per-host toggle — a host opts out of
  # display management by not importing
  # `flake.modules.homeManager.displays` into its HM config, which is
  # what actually gates the tools and the `displays.outputs` option.
  # The signal exists so niri.nix has a seam to read rather than
  # hardcoding a path this module owns; the include it guards is
  # `optional=true`, so emitting it on a host without this HM module is
  # harmless (a log warning, nothing more).
  options.displays = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
      description = ''
        Signal set by this module when imported. Read by niri.nix to
        prepend the mutable-layout include. Not meant to be set by
        hand — import the module instead.
      '';
    };
  };

  config.displays.enable = lib.mkDefault true;

  config.flake.modules.homeManager.displays = { config, pkgs, ... }:
    let
      # Path is duplicated in niri.nix's include line. Keep in sync.
      localLayout = "$HOME/.config/niri/outputs.local.kdl";

      # niri reports transforms in JSON as PascalCase but accepts them
      # in KDL as lowercase/hyphenated. Verified live against
      # niri 2026-07-08 by round-tripping each value through
      # `niri msg output <name> transform <x>` and reading back
      # `niri msg --json outputs`:
      #     normal -> Normal        flipped     -> Flipped
      #     90     -> 90            flipped-90  -> Flipped90
      #     180    -> 180           flipped-180 -> Flipped180
      #     270    -> 270           flipped-270 -> Flipped270
      # Getting this wrong writes a KDL file niri refuses to parse,
      # which takes the whole config down — not just the layout.
      displaySave = pkgs.writeShellApplication {
        name = "display-save";
        runtimeInputs = [ pkgs.python3 ];
        # SC2016: the single-quoted block is a Python program passed to
        # `python3 -c`, so shell expansion inside it is exactly what we
        # must NOT have. The warning is a false positive here.
        excludeShellChecks = [ "SC2016" ];
        text = ''
                    out="${localLayout}"
                    mkdir -p "$(dirname "$out")"
                    tmp="$(mktemp)"
                    trap 'rm -f "$tmp"' EXIT

                    niri msg --json outputs | python3 -c '
          import json, sys

          TRANSFORM = {
              "Normal": "normal",
              "90": "90",
              "180": "180",
              "270": "270",
              "Flipped": "flipped",
              "Flipped90": "flipped-90",
              "Flipped180": "flipped-180",
              "Flipped270": "flipped-270",
          }

          outputs = json.load(sys.stdin)
          print("// Generated by `display-save`. Edit with wdisplays, not by hand.")
          print("// Delete this file (or run `display-reset`) to fall back to the")
          print("// declarative layout from the Nix config.")
          print()

          for connector, o in sorted(outputs.items()):
              logical = o.get("logical")
              if logical is None:
                  # Output is off. Preserve that, keyed the same way as below.
                  pass

              make, model, serial = o.get("make"), o.get("model"), o.get("serial")
              # Mirror niri format_make_model_serial_or_connector(): fall back to
              # the connector only when make/model/serial are all absent.
              if make or model or serial:
                  name = "{} {} {}".format(make or "Unknown", model or "Unknown",
                                           serial or "Unknown")
              else:
                  name = connector

              print("output {} {{".format(json.dumps(name)))

              if logical is None:
                  print("    off")
                  print("}")
                  print()
                  continue

              modes = o.get("modes") or []
              idx = o.get("current_mode")
              if idx is not None and 0 <= idx < len(modes):
                  m = modes[idx]
                  # refresh_rate is in mHz; niri wants exactly three decimals.
                  print("    mode \"{}x{}@{:.3f}\"".format(
                      m["width"], m["height"], m["refresh_rate"] / 1000.0))

              scale = logical.get("scale")
              if scale is not None:
                  print("    scale {}".format(
                      int(scale) if float(scale).is_integer() else scale))

              print("    position x={} y={}".format(logical.get("x", 0),
                                                    logical.get("y", 0)))

              tf = TRANSFORM.get(logical.get("transform", "Normal"), "normal")
              if tf != "normal":
                  print("    transform \"{}\"".format(tf))

              if o.get("vrr_enabled"):
                  print("    variable-refresh-rate")

              print("}")
              print()
          ' > "$tmp"

                    # Never leave a broken layout behind: a KDL syntax error in an
                    # included file fails the WHOLE config, so validate before
                    # installing. niri validate needs a complete config, so check
                    # the real one with the candidate file swapped in.
                    if [ -s "$tmp" ]; then
                      backup=""
                      if [ -f "$out" ]; then
                        backup="$(mktemp)"
                        cp "$out" "$backup"
                      fi
                      cp "$tmp" "$out"
                      if niri validate >/dev/null 2>&1; then
                        echo "display-save: saved current layout to $out"
                        [ -n "$backup" ] && rm -f "$backup"
                      else
                        if [ -n "$backup" ]; then
                          cp "$backup" "$out"; rm -f "$backup"
                          echo "display-save: generated layout failed validation; kept previous" >&2
                        else
                          rm -f "$out"
                          echo "display-save: generated layout failed validation; discarded" >&2
                        fi
                        exit 1
                      fi
                    else
                      echo "display-save: produced no output; nothing saved" >&2
                      exit 1
                    fi
        '';
      };

      displayReset = pkgs.writeShellApplication {
        name = "display-reset";
        text = ''
          out="${localLayout}"
          if [ -f "$out" ]; then
            rm -f "$out"
            echo "display-reset: removed $out; reverting to the Nix layout."
            echo "(niri live-reloads, so this takes effect immediately.)"
          else
            echo "display-reset: no saved layout at $out; already on the Nix layout."
          fi
        '';
      };

      # Promotion path: print the current arrangement as a Nix snippet
      # to paste into a host bridge. This is what keeps the mutable
      # layer from quietly becoming the real source of truth.
      displayExport = pkgs.writeShellApplication {
        name = "display-export";
        runtimeInputs = [ pkgs.python3 ];
        # See the SC2016 note on display-save above.
        excludeShellChecks = [ "SC2016" ];
        text = ''
                    niri msg --json outputs | python3 -c '
          import json, sys

          TRANSFORM = {
              "Normal": "normal", "90": "90", "180": "180", "270": "270",
              "Flipped": "flipped", "Flipped90": "flipped-90",
              "Flipped180": "flipped-180", "Flipped270": "flipped-270",
          }

          outputs = json.load(sys.stdin)
          print("# Paste into the host bridge (see flake-modules/hosts/*.nix).")
          print("displays.outputs = {")

          for connector, o in sorted(outputs.items()):
              make, model, serial = o.get("make"), o.get("model"), o.get("serial")
              if make or model or serial:
                  name = "{} {} {}".format(make or "Unknown", model or "Unknown",
                                           serial or "Unknown")
              else:
                  name = connector

              logical = o.get("logical")
              print("  {} = {{".format(json.dumps(name)))

              if logical is None:
                  print("    off = true;")
                  print("  };")
                  continue

              modes = o.get("modes") or []
              idx = o.get("current_mode")
              if idx is not None and 0 <= idx < len(modes):
                  m = modes[idx]
                  print("    mode = \"{}x{}@{:.3f}\";".format(
                      m["width"], m["height"], m["refresh_rate"] / 1000.0))

              scale = logical.get("scale")
              if scale is not None:
                  print("    scale = {};".format(
                      int(scale) if float(scale).is_integer() else scale))

              print("    position = {{ x = {}; y = {}; }};".format(
                  logical.get("x", 0), logical.get("y", 0)))

              tf = TRANSFORM.get(logical.get("transform", "Normal"), "normal")
              if tf != "normal":
                  print("    transform = \"{}\";".format(tf))

              if o.get("vrr_enabled"):
                  print("    variable-refresh-rate = \"on\";")

              print("  };")

          print("};")
          '
        '';
      };
    in
    {
      options.displays.outputs = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule outputOpts);
        default = { };
        example = lib.literalExpression ''
          {
            # Match by connector for the built-in panel...
            "eDP-1".scale = 1;
            # ...and by "MAKE MODEL SERIAL" for external monitors, which
            # is stable across docks and connector renumbering.
            "Samsung Electric Company C32R50x H1AK500000" = {
              mode = "1920x1080@60.000";
              position = { x = 1920; y = 0; };
            };
          }
        '';
        description = ''
          Per-output display configuration, rendered into niri `output`
          blocks.

          Prefer keying on `"MAKE MODEL SERIAL"` (exactly as printed by
          `niri msg outputs`) rather than a connector name like `DP-2`.
          Connector numbering depends on which physical port a dock
          happens to route a monitor through and is not stable across
          docks — the same monitor can be DP-2 today and DP-4 tomorrow.
          Make/model/serial follows the monitor itself.

          These are DEFAULTS: a saved runtime layout
          (`~/.config/niri/outputs.local.kdl`, written by `display-save`)
          takes precedence while it exists, because it is included first.
          Run `display-reset` to drop it and fall back to these values.
        '';
      };

      config.home.packages = [
        # GUI display arranger. Speaks zwlr_output_management_v1, which
        # niri implements (src/protocols/output_management.rs), so
        # drag-to-arrange / resolution / scale all work live.
        pkgs.wdisplays
        displaySave
        displayReset
        displayExport
      ];

      # Mod+D opens the arranger; Mod+Shift+D saves the result.
      # Deliberately adjacent so "rearrange, then persist" is one
      # motion. Both were free in flake-modules/niri/binds.nix.
      #
      # The hotkey-overlay titles are load-bearing beyond niri's own
      # overlay: flake-modules/discovery.nix lists a bind in the `guide`
      # cheat sheet iff it carries one. See that file's header.
      config.programs.niri.settings.binds = {
        "Mod+D" = {
          hotkey-overlay.title = "Arrange your monitors (drag them into place)";
          action.spawn = "wdisplays";
        };
        "Mod+Shift+D" = {
          hotkey-overlay.title = "Remember this monitor arrangement";
          action.spawn = "display-save";
        };
      };

      # Declarative layer. Rendered into niri `output` blocks; overridden
      # by outputs.local.kdl while that file exists (see header).
      # Map our option names onto niri-flake's schema (verified against
      # niri-flake settings.nix:1808-1910). Note the mismatches:
      #   * niri-flake uses `enable` (default true), not `off`.
      #   * `transform` is a record { flipped, rotation }, not a string.
      #   * `variable-refresh-rate` is an enum false | "on-demand" | true.
      # filterAttrs drops nulls so unset options fall through to niri's
      # own defaults rather than being pinned.
      config.programs.niri.settings.outputs = lib.mapAttrs
        (_name: o:
          lib.filterAttrs (_: v: v != null) ({
            enable = !o.off;
            inherit (o) focus-at-startup;
            mode = o.mode;
            scale = o.scale;
            position = o.position;
            variable-refresh-rate =
              if o.variable-refresh-rate == null then false
              else if o.variable-refresh-rate == "on-demand" then "on-demand"
              else true;
          } // lib.optionalAttrs (o.transform != null) {
            transform =
              let
                flipped = lib.hasPrefix "flipped" o.transform;
                degrees = lib.removePrefix "flipped-" o.transform;
              in
              {
                inherit flipped;
                rotation =
                  if degrees == "normal" || degrees == "flipped" then 0
                  else lib.toInt degrees;
              };
          }))
        config.displays.outputs;
    };
}
