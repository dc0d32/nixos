#!/usr/bin/env bash
#
# biometrics-enroll — interactive fingerprint + face enrollment helper.
#
# Wraps fprintd-enroll + linux-enable-ir-emitter configure + howdy
# add into one discoverable command. Run as the calling user (NOT
# root); the script invokes sudo internally for the steps that need
# it (IR emitter calibration, howdy enrollment).
#
# Subcommands: fingerprint | face | all (default) | verify.
#
# This script is installed system-wide as `biometrics-enroll` via
# flake-modules/biometrics.nix using pkgs.writeShellApplication,
# which (a) puts fprintd / howdy / linux-enable-ir-emitter on PATH
# at runtime and (b) runs shellcheck at build time. So this file
# itself doesn't need shebangs/PATH munging when consumed by the
# nix build, but the shebang above keeps it directly executable
# during local development / testing.
#
# Retire when: nixpkgs ships an equivalent enrollment TUI, or the
# howdy/fprintd setup becomes a one-liner upstream.

set -euo pipefail

# ── plumbing ──────────────────────────────────────────
usage() {
  cat <<'USAGE'
biometrics-enroll — interactive fingerprint + face enrollment.

Usage: biometrics-enroll [SUBCOMMAND]

Subcommands:
  all          Enroll fingerprint(s) then face. (default)
  fingerprint  Enroll one or more fingerprints.
  face         Calibrate IR emitter (if needed) and enroll face.
  verify       Test fingerprint and face authentication.
  -h, --help   Show this message.

Run as your own user. The script invokes sudo only for
the steps that need it (IR emitter calibration, howdy).
USAGE
}

require_user() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "error: do not run biometrics-enroll as root." >&2
    echo "       Run it as your own user; sudo is invoked internally." >&2
    exit 1
  fi
}

confirm() {
  # confirm "prompt" "default" → returns 0 for yes, 1 for no.
  local prompt="$1" default="${2:-n}" reply
  local hint="[y/N]"
  [ "$default" = "y" ] && hint="[Y/n]"
  read -r -p "$prompt $hint " reply || reply=""
  reply="${reply:-$default}"
  case "$reply" in
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

# ── fingerprint ───────────────────────────────────────
FINGER_SLOTS=(
  right-index-finger
  left-index-finger
  right-thumb
  left-thumb
  right-middle-finger
  left-middle-finger
  right-ring-finger
  left-ring-finger
  right-little-finger
  left-little-finger
)

list_enrolled_fingers() {
  # fprintd-list prints something like:
  #   found 2 fingers enrolled for user p:
  #    - #0: right-index-finger
  #    - #1: left-index-finger
  # Tolerate "no fingers enrolled" (exit 0, empty output).
  fprintd-list "$USER" 2>/dev/null \
    | awk -F': ' '/^ - #/ {print $2}' \
    || true
}

pick_finger_slot() {
  # Print a finger slot name to stdout (no other output
  # on stdout — prompts go to stderr).
  local enrolled choice i
  enrolled=$(list_enrolled_fingers | tr "\n" " ")
  {
    echo
    echo "Available finger slots:"
    for i in "${!FINGER_SLOTS[@]}"; do
      local slot="${FINGER_SLOTS[$i]}" mark=""
      case " $enrolled " in
        *" $slot "*) mark=" (already enrolled — re-enrolling overwrites)" ;;
      esac
      printf "  %2d) %s%s\n" "$((i + 1))" "$slot" "$mark"
    done
    echo
  } >&2
  while :; do
    read -r -p "Pick a finger [1-${#FINGER_SLOTS[@]}], or 'q' to stop: " choice >&2 || choice=q
    case "$choice" in
      q|Q|"")     return 1 ;;
      *[!0-9]*)   echo "  not a number." >&2 ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le ${#FINGER_SLOTS[@]} ]; then
          echo "${FINGER_SLOTS[$((choice - 1))]}"
          return 0
        fi
        echo "  out of range." >&2
        ;;
    esac
  done
}

do_fingerprint() {
  echo "═══ Fingerprint enrollment ═══"
  local enrolled
  enrolled=$(list_enrolled_fingers)
  if [ -n "$enrolled" ]; then
    echo "Currently enrolled for $USER:"
    echo "  ${enrolled//$'\n'/$'\n  '}"
    echo
    if confirm "Clear existing fingerprints first?" n; then
      fprintd-delete "$USER"
      echo "  cleared."
    fi
  fi
  local slot first=1
  while :; do
    local prompt="Enroll a fingerprint?"
    [ $first -eq 0 ] && prompt="Enroll another fingerprint?"
    if ! confirm "$prompt" "$([ $first -eq 1 ] && echo y || echo n)"; then
      break
    fi
    slot=$(pick_finger_slot) || break
    echo
    echo ">> enrolling $slot for $USER (place finger when prompted) …"
    fprintd-enroll -f "$slot" "$USER"
    first=0
  done
  echo "Done. Enrolled fingers:"
  list_enrolled_fingers | sed "s/^/  /"
}

# ── face ─────────────────────────────────────────────
ir_emitter_calibrated() {
  # linux-enable-ir-emitter persists driver config in
  # /var/lib/linux-enable-ir-emitter (root-owned). We
  # check existence via sudo so a non-root user can
  # still see whether prior calibration exists.
  sudo test -d /var/lib/linux-enable-ir-emitter \
    && sudo find /var/lib/linux-enable-ir-emitter \
           -mindepth 1 -maxdepth 2 -print -quit \
       | grep -q .
}

list_enrolled_faces() {
  # `howdy list` prints one line per model, or an error
  # message if no models exist. Filter to model lines.
  # howdy uses `-U USER` (not a positional) for user
  # selection.
  sudo howdy -U "$USER" list 2>/dev/null \
    | awk "/^[0-9]+/" \
    || true
}

do_face() {
  echo "═══ Face enrollment ═══"
  # 1. IR emitter calibration. The configure step is
  # interactive and shows a live IR preview window — it
  # MUST be run from a Wayland/X session, not a plain
  # TTY. We pass -E so sudo preserves DISPLAY/WAYLAND_*.
  echo
  if ir_emitter_calibrated; then
    echo "IR emitter appears already calibrated."
    if confirm "Re-run calibration anyway?" n; then
      sudo -E linux-enable-ir-emitter configure
    fi
  else
    echo "IR emitter needs one-time calibration. A live IR preview"
    echo "window will open — answer the prompts about whether the"
    echo "emitter is flashing."
    echo
    if confirm "Run linux-enable-ir-emitter configure now?" y; then
      sudo -E linux-enable-ir-emitter configure
    else
      echo "  skipped. Face enrollment may not work without it."
    fi
  fi

  # 2. Face enrollment. `howdy add` prompts for a model
  # label and captures one frame; you can run it
  # multiple times to add models for glasses / no-
  # glasses / different lighting.
  local existing
  existing=$(list_enrolled_faces)
  if [ -n "$existing" ]; then
    echo
    echo "Existing face models for $USER:"
    echo "  ${existing//$'\n'/$'\n  '}"
    if confirm "Clear existing face models first?" n; then
      sudo howdy -U "$USER" clear
      echo "  cleared."
    fi
  fi
  local first=1
  while :; do
    local prompt="Add a face model?"
    [ $first -eq 0 ] && prompt="Add another face model? (e.g. glasses / no-glasses / different lighting)"
    if ! confirm "$prompt" "$([ $first -eq 1 ] && echo y || echo n)"; then
      break
    fi
    echo
    echo ">> running 'sudo howdy -U $USER add' (look at the camera) …"
    sudo howdy -U "$USER" add
    first=0
  done
  echo "Done. Face models for $USER:"
  list_enrolled_faces | sed "s/^/  /"
}

# ── verify ───────────────────────────────────────────
do_verify() {
  echo "═══ Verification ═══"
  echo
  echo ">> fprintd-verify (touch the sensor) …"
  if fprintd-verify "$USER"; then
    echo "  fingerprint: OK"
  else
    echo "  fingerprint: FAILED (or not enrolled)"
  fi
  echo
  echo ">> howdy test (look at the camera, ~3s) …"
  if sudo howdy -U "$USER" test; then
    echo "  face: OK"
  else
    echo "  face: FAILED (or not enrolled / IR emitter off)"
  fi
}

# ── dispatch ─────────────────────────────────────────
require_user
case "${1:-all}" in
  all)         do_fingerprint; echo; do_face ;;
  fingerprint) do_fingerprint ;;
  face)        do_face ;;
  verify)      do_verify ;;
  -h|--help)   usage ;;
  *)           usage; exit 2 ;;
esac
