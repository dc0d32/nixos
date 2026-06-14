#!/usr/bin/env bash
# audio-discover — print a `audio.autoloads` entry for this host's
# currently-default PipeWire sink. Run once on real hardware after
# wiring a host's `audio.presetsDir`, then paste the printed entry
# into the host bridge's `audio.autoloads = [ ... ]` list with the
# desired EasyEffects preset name.
#
# Read-only — no root, no flake build. Pure probe of the running
# PipeWire daemon. Requires wireplumber (ships `wpctl`); every host
# that imports flake-modules/audio.nix has it.
#
# Retire when: PipeWire/wireplumber land a one-shot autoload-rule
# generator upstream, or when EasyEffects gains a "save current
# loaded preset as autoload rule" UI button.
set -euo pipefail

if ! command -v wpctl >/dev/null 2>&1; then
    echo "error: wpctl not found in PATH." >&2
    echo "       wpctl ships with wireplumber; this host should have" >&2
    echo "       it via flake-modules/audio.nix's NixOS-side import." >&2
    exit 1
fi

if ! inspect=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>&1); then
    echo "error: \`wpctl inspect @DEFAULT_AUDIO_SINK@\` failed:" >&2
    echo "$inspect" >&2
    echo
    echo "Is PipeWire running? Try: systemctl --user status pipewire wireplumber" >&2
    exit 1
fi

node_name=$(printf '%s\n' "$inspect" \
    | sed -n 's/^[* ]*node\.name = "\(.*\)"$/\1/p' \
    | head -n1)
node_desc=$(printf '%s\n' "$inspect" \
    | sed -n 's/^[* ]*node\.description = "\(.*\)"$/\1/p' \
    | head -n1)
profile_name=$(printf '%s\n' "$inspect" \
    | sed -n 's/^[* ]*device\.profile\.name = "\(.*\)"$/\1/p' \
    | head -n1)

if [[ -z "$node_name" ]]; then
    echo "error: could not parse node.name from wpctl inspect output." >&2
    echo "Raw output for debugging:" >&2
    echo "$inspect" >&2
    exit 1
fi

# Fallback for profile_name: derive from node.name suffix.
if [[ -z "$profile_name" ]]; then
    if [[ "$node_name" == *.HiFi__*__sink ]]; then
        profile_name="${node_name##*.HiFi__}"
        profile_name="${profile_name%__sink}"
    else
        profile_name="${node_name##*.}"
    fi
fi

if [[ -z "$node_desc" ]]; then
    node_desc="(unknown — set me to match \`wpctl status\`)"
fi

cat <<EOF
# Paste this into the host bridge's \`audio.autoloads = [ ... ]\`
# list (e.g. flake-modules/hosts/<this-host>.nix), replacing the
# preset = "..." value with the EasyEffects preset name you want
# bound to this sink (one of the .json files under
# hosts/<this-host>/audio-presets/, without the .json extension).
{
  device = "$node_name";
  profile = "$profile_name";
  description = "$node_desc";
  preset = "CHANGE-ME";
}
EOF
