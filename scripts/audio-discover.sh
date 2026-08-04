#!/usr/bin/env bash
# audio-discover — print `audio.autoloads` / `audio.inputAutoloads`
# entries for this host's currently-default PipeWire sink and source.
# Run once on real hardware after wiring a host's `audio.presetsDir`,
# then paste the printed entries into the host bridge with the desired
# EasyEffects preset names.
#
# Read-only — no root, no flake build. Pure probe of the running
# PipeWire daemon. Requires wireplumber (ships `wpctl`); `pw-dump` +
# `jq` are used when available for an exact answer and the script
# degrades to wpctl-only parsing otherwise.
#
# The `profile` field is the trap here. EasyEffects builds the autoload
# rule filename as "<node.name>:<device route description>.json" —
# `node.device_route_description` in presets_autoload_manager.cpp, which
# pw_manager.cpp fills from the *Route* param's `description`. That is
# NOT `device.profile.name` ("HiFi: Speaker: sink"), which an earlier
# version of this script printed and which silently never matches.
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

have_dump=0
if command -v pw-dump >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    if dump=$(pw-dump 2>/dev/null); then
        have_dump=1
    fi
fi

# route_description <node-name> <Input|Output>
#
# Resolve the node's owning device, then pick the Route whose `device`
# index matches the node's `card.profile.device`. That is exactly the
# lookup EasyEffects does.
route_description() {
    local node="$1" direction="$2"
    [[ "$have_dump" -eq 1 ]] || return 0
    jq -r --arg node "$node" --arg dir "$direction" '
        (map(select(.info.props."node.name" == $node)) | first) as $n
        | if $n == null then empty else
            ($n.info.props."device.id") as $devid
          | ($n.info.props."card.profile.device") as $cpd
          | map(select(.id == $devid))
          | first
          | .info.params.Route // []
          | map(select(.direction == $dir
                       and (($cpd | tostring) == (.device | tostring))))
          | first
          | .description // empty
          end
    ' <<<"$dump" 2>/dev/null || true
}

emit() {
    local target="$1" direction="$2" option="$3" assets="$4"
    local inspect node_name node_desc profile

    if ! inspect=$(wpctl inspect "$target" 2>&1); then
        echo "warning: \`wpctl inspect $target\` failed; skipping." >&2
        echo "$inspect" >&2
        return 0
    fi

    node_name=$(sed -n 's/^[* ]*node\.name = "\(.*\)"$/\1/p' <<<"$inspect" | head -n1)
    node_desc=$(sed -n 's/^[* ]*node\.description = "\(.*\)"$/\1/p' <<<"$inspect" | head -n1)

    if [[ -z "$node_name" ]]; then
        echo "warning: could not parse node.name for $target; skipping." >&2
        return 0
    fi

    profile=$(route_description "$node_name" "$direction")

    # Fallback 1: `device.profile.description` is the route description
    # for UCM-driven cards (it is "Speaker" where device.profile.name is
    # "HiFi: Speaker: sink"). It can disagree on legacy analog profiles,
    # hence the pw-dump path above being preferred.
    if [[ -z "$profile" ]]; then
        profile=$(sed -n 's/^[* ]*device\.profile\.description = "\(.*\)"$/\1/p' \
            <<<"$inspect" | head -n1)
    fi

    # Fallback 2: derive from the node.name suffix.
    if [[ -z "$profile" ]]; then
        if [[ "$node_name" == *.HiFi__*__sink || "$node_name" == *.HiFi__*__source ]]; then
            profile="${node_name##*.HiFi__}"
            profile="${profile%__sink}"
            profile="${profile%__source}"
        else
            profile="${node_name##*.}"
        fi
        echo "warning: guessed profile=\"$profile\" for $node_name." >&2
        echo "         Install jq (or check pw-dump) for an exact value." >&2
    fi

    [[ -n "$node_desc" ]] || node_desc="(unknown — set me to match \`wpctl status\`)"

    cat <<EOF

# ── $option ────────────────────────────────────────────
# Paste into the host bridge (flake-modules/hosts/<this-host>.nix),
# replacing preset = "..." with the EasyEffects preset name you want
# bound to this device — one of the .json files under
# hosts/<this-host>/$assets/, without the .json extension.
{
  device = "$node_name";
  profile = "$profile";
  description = "$node_desc";
  preset = "CHANGE-ME";
}
EOF
}

emit @DEFAULT_AUDIO_SINK@ Output audio.autoloads audio-presets
emit @DEFAULT_AUDIO_SOURCE@ Input audio.inputAutoloads audio-presets-input

cat <<'EOF'

# Devices with no entry get audio.fallbackPreset / audio.inputFallbackPreset
# (the generated "Passthrough" preset, i.e. no processing at all), so
# bluetooth, HDMI and dock outputs stay on the stock audio path.
EOF
