#!/usr/bin/env bash
# egghead — opinionated NixOS installer wizard for this flake.
#
# Boots from the official NixOS installer ISO, runs
#   `nix run github:dc0d32/nixos#egghead`
# and walks the operator through the per-host questions (hostname,
# role, disk, users, features, locale). On success it writes a fresh
# `flake-modules/hosts/<name>.nix` + `hosts/<name>/hardware-configuration.nix`
# into a writable checkout of the flake, commits both files, then execs
# `scripts/host-setup.sh --install <name> --no-regen-hwconfig` to do the
# actual disko + nixos-install + home-manager bootstrap.
#
# Phase 1 (this file): shell-stub UI. Plain `read -p` prompts. No deps
# beyond what the installer ISO ships (bash, coreutils, util-linux,
# git, nix). Phase 3 will rewrite the UI layer in TypeScript + Ink.
#
# Non-interactive use: every prompt honours an EGGHEAD_* env var as
# the answer source. Set them all to feed the wizard from a config
# file in tests / golden-master comparisons. See `egghead --help`.
#
# See AGENTS.md ("Adding a new host") and docs/runbooks/ for the
# hand-rolled bridge file convention this wizard matches.

set -euo pipefail

# ─── Build-time defaults (writeShellApplication substitution targets) ───
# flake-modules/egghead.nix bakes the real flake URL/ref into this
# script via environment-variable defaults so `nix run` keeps working
# without arguments. Override at runtime with --flake-url / --flake-ref.
: "${EGGHEAD_FLAKE_URL:=https://github.com/dc0d32/nixos.git}"
: "${EGGHEAD_FLAKE_REF:=main}"
: "${EGGHEAD_DEFAULT_STATE_VERSION:=25.11}"

WORKDIR="${EGGHEAD_WORKDIR:-/tmp/egghead-checkout}"
DO_INSTALL=1
DO_CLONE=1
NONINTERACTIVE=0

show_help() {
    cat <<EOF
egghead — opinionated NixOS installer wizard

USAGE:
    egghead [OPTIONS]
    egghead --help

OPTIONS:
    --flake-url URL    git URL to clone (default: $EGGHEAD_FLAKE_URL)
    --flake-ref REF    git ref to check out (default: $EGGHEAD_FLAKE_REF)
    --workdir DIR      where to put the cloned flake (default: $WORKDIR)
    --no-clone         skip the clone step; assume WORKDIR already
                       contains a flake checkout. Useful when iterating
                       on egghead itself on a host that already has
                       this repo.
    --no-install       generate the host bridge + commit, but stop
                       before exec'ing host-setup.sh --install. Use for
                       dry runs and tests; no disks are touched.
    --non-interactive  fail if any required answer is missing from
                       EGGHEAD_* env vars. Implies no read prompts.
    --help             show this help

INTERACTIVE PROMPTS:
    The wizard asks for, in order:
      1. hostname             (EGGHEAD_HOSTNAME)
      2. role template        (EGGHEAD_ROLE: bare-metal-laptop |
                                bare-metal-desktop | vm-headless |
                                vm-desktop)
      3. target disk          (EGGHEAD_DISK, e.g. /dev/nvme0n1)
      3a. swap size            (EGGHEAD_SWAP_SIZE; e.g. "32G", "12G",
                                or "" for no swap. Default is
                                installed RAM size rounded up to GiB,
                                which is what hibernate needs.)
      4. primary user         (EGGHEAD_PRIMARY_USER)
      5. primary full name    (EGGHEAD_PRIMARY_FULLNAME)
      6. primary password     (EGGHEAD_PRIMARY_PASSWORD plain, OR
                                EGGHEAD_PRIMARY_HASHED_PASSWORD
                                pre-hashed yescrypt)
      7. additional users     (EGGHEAD_EXTRA_USERS_JSON; JSON array
                                of {login, fullname, profile,
                                password|hashedPassword}; interactive
                                flow loops "add another user?")
      8. feature toggles      (EGGHEAD_FEATURES, space-separated
                                module names; defaults from role)
      9. gpu driver           (EGGHEAD_GPU_DRIVER: intel|amd|nvidia|
                                none)
     10. timezone             (EGGHEAD_TZ, default America/Los_Angeles)
     11. locale               (EGGHEAD_LOCALE, default en_US.UTF-8)
     12. keymap               (EGGHEAD_KEYMAP, default us)
     13. LUKS full-disk       (EGGHEAD_LUKS: yes|no, default no)
                                encryption
     13a. LUKS passphrase     (EGGHEAD_LUKS_PASSPHRASE plain; only
                                if LUKS=yes. Required for TPM
                                enrollment. Stays in tmpfs, never
                                committed.)
     13b. TPM auto-unlock     (EGGHEAD_LUKS_TPM: yes|no; only if
                                LUKS=yes. Defaults yes when
                                /dev/tpmrm0 exists. Enrolls
                                systemd-cryptenroll TPM2 keyslot
                                bound to PCR 7; LUKS passphrase
                                remains as fallback keyslot.)
     14. root password        (EGGHEAD_ROOT_PASSWORD plain or
                                EGGHEAD_ROOT_HASHED_PASSWORD;
                                default 'recovery'. Empty = no
                                root login. Acts as console + SSH
                                recovery if graphics break.)

    HM profiles per user: base | dev | desktop | kid (maps to bundles
    in flake-modules/bundles/).

EXAMPLES:
    # Fully interactive from the installer ISO. The official NixOS
    # ISO ships without nix-command/flakes enabled, so pass them
    # inline:
    sudo nix --extra-experimental-features 'nix-command flakes' \\
        run github:dc0d32/nixos#egghead

    # Dry-run with overrides for hostname + role
    EGGHEAD_HOSTNAME=test-host EGGHEAD_ROLE=vm-desktop \\
        nix run github:dc0d32/nixos#egghead -- --no-install

    # Iterate locally against an already-checked-out flake
    nix run .#egghead -- --no-clone --workdir "\$PWD" --no-install
EOF
}

# ─── arg parse ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --flake-url) EGGHEAD_FLAKE_URL="$2"; shift 2 ;;
        --flake-ref) EGGHEAD_FLAKE_REF="$2"; shift 2 ;;
        --workdir)   WORKDIR="$2"; shift 2 ;;
        --no-clone)  DO_CLONE=0; shift ;;
        --no-install) DO_INSTALL=0; shift ;;
        --non-interactive) NONINTERACTIVE=1; shift ;;
        --help|-h)   show_help; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2
            echo "       run: egghead --help" >&2
            exit 2
            ;;
    esac
done

# ─── prompt helpers ───────────────────────────────────────────────
# ask VAR "prompt text" "default"
#   * Reads environment variable `EGGHEAD_$VAR` first; if set, uses
#     that as the answer (no prompt). This is the non-interactive
#     contract documented in --help.
#   * Else, in --non-interactive mode, errors out unless a default is
#     provided.
#   * Else, prompts the user with the default in [brackets]; empty
#     answer accepts the default.
ask() {
    local __var="$1" prompt="$2"
    local has_default=0 default=""
    if (( $# >= 3 )); then has_default=1; default="$3"; fi
    local __envname="EGGHEAD_$__var"
    # `${!name+x}` distinguishes "env var is set (possibly empty)"
    # from "env var is unset". Treating an explicit empty env value
    # as a deliberate answer matters for EGGHEAD_EXTRA_USERS="" etc.
    if [[ -n "${!__envname+x}" ]]; then
        printf -v "$__var" '%s' "${!__envname}"
        echo ">> $prompt: ${!__var}  (from \$$__envname)" >&2
        return 0
    fi
    if (( NONINTERACTIVE )); then
        if (( has_default )); then
            printf -v "$__var" '%s' "$default"
            echo ">> $prompt: $default  (default, --non-interactive)" >&2
            return 0
        fi
        echo "error: --non-interactive but \$$__envname unset and no default" >&2
        exit 2
    fi
    local reply
    if (( has_default )); then
        read -r -p "$prompt [$default]: " reply
        reply="${reply:-$default}"
    else
        read -r -p "$prompt: " reply
        while [[ -z "$reply" ]]; do
            read -r -p "  (required) $prompt: " reply
        done
    fi
    printf -v "$__var" '%s' "$reply"
}

# ask_choice VAR "prompt" "default" "opt1 opt2 opt3"
ask_choice() {
    local __var="$1" prompt="$2" default="$3" choices="$4"
    local __envname="EGGHEAD_$__var"
    if [[ -n "${!__envname+x}" ]]; then
        printf -v "$__var" '%s' "${!__envname}"
        echo ">> $prompt: ${!__var}  (from \$$__envname)" >&2
        return 0
    fi
    if (( NONINTERACTIVE )); then
        printf -v "$__var" '%s' "$default"
        echo ">> $prompt: $default  (default, --non-interactive)" >&2
        return 0
    fi
    local reply
    while true; do
        read -r -p "$prompt {$choices} [$default]: " reply
        reply="${reply:-$default}"
        for c in $choices; do
            if [[ "$reply" == "$c" ]]; then
                printf -v "$__var" '%s' "$reply"
                return 0
            fi
        done
        echo "  invalid: must be one of: $choices"
    done
}

# ask_yesno VAR "prompt" "default" (default: yes|no)
ask_yesno() {
    local __var="$1" prompt="$2" default="$3" reply
    local __envname="EGGHEAD_$__var"
    if [[ -n "${!__envname+x}" ]]; then
        printf -v "$__var" '%s' "${!__envname}"
        echo ">> $prompt: ${!__var}  (from \$$__envname)" >&2
        return 0
    fi
    if (( NONINTERACTIVE )); then
        printf -v "$__var" '%s' "$default"
        return 0
    fi
    while true; do
        read -r -p "$prompt (y/n) [$default]: " reply
        reply="${reply:-$default}"
        case "$reply" in
            y|Y|yes|YES) printf -v "$__var" '%s' "yes"; return 0 ;;
            n|N|no|NO)   printf -v "$__var" '%s' "no";  return 0 ;;
            *) echo "  invalid: y or n" ;;
        esac
    done
}

# hash_password OUTVAR plain
#   Hashes plain → yescrypt and assigns to OUTVAR. Empty plain → empty
#   hash (caller treats as "no login"). mkpasswd reads from stdin with
#   -s so the plaintext never appears on a command line / in argv /
#   in `ps`.
hash_password() {
    local __out="$1" plain="$2"
    if [[ -z "$plain" ]]; then
        printf -v "$__out" '%s' ""
        return 0
    fi
    # Distinct name (`__h`) to avoid clobbering a caller-local
    # `hashed`: `printf -v "$__out"` resolves the name at runtime
    # but `local` at function entry shadows any matching name in
    # the caller's scope, so naming the internal temporary the
    # same as a common caller-side variable silently breaks the
    # write-back.
    local __h
    __h=$(printf '%s' "$plain" | mkpasswd -m yescrypt -s)
    printf -v "$__out" '%s' "$__h"
}

# ask_password OUTVAR_HASH "prompt" "default-plain"
#   Three input sources, in priority order:
#     1. EGGHEAD_<basename>_HASHED_PASSWORD  → use verbatim
#     2. EGGHEAD_<basename>_PASSWORD         → hash and use
#     3. interactive                         → prompt twice with -s,
#                                              then hash
#   `basename` is OUTVAR_HASH with a trailing _HASHED_PASSWORD stripped
#   (so a caller passing `PRIMARY_HASHED_PASSWORD` looks up
#   `EGGHEAD_PRIMARY_HASHED_PASSWORD` then `EGGHEAD_PRIMARY_PASSWORD`).
#   Default-plain is used when both env vars are unset AND we're
#   --non-interactive; empty default in --non-interactive is allowed
#   (= "no login").
ask_password() {
    local __out="$1" prompt="$2" default_plain="${3-}"
    local base="${__out%_HASHED_PASSWORD}"
    local env_hashed="EGGHEAD_${base}_HASHED_PASSWORD"
    local env_plain="EGGHEAD_${base}_PASSWORD"

    if [[ -n "${!env_hashed+x}" ]]; then
        printf -v "$__out" '%s' "${!env_hashed}"
        echo ">> $prompt: (hash from \$$env_hashed)" >&2
        return 0
    fi
    if [[ -n "${!env_plain+x}" ]]; then
        hash_password "$__out" "${!env_plain}"
        echo ">> $prompt: (hashed from \$$env_plain)" >&2
        return 0
    fi
    if (( NONINTERACTIVE )); then
        hash_password "$__out" "$default_plain"
        if [[ -z "$default_plain" ]]; then
            echo ">> $prompt: (empty — no login, --non-interactive)" >&2
        else
            echo ">> $prompt: (default plain, --non-interactive)" >&2
        fi
        return 0
    fi

    local p1 p2
    while true; do
        if [[ -n "$default_plain" ]]; then
            read -r -s -p "$prompt [press Enter to accept default]: " p1
            echo
            if [[ -z "$p1" ]]; then
                hash_password "$__out" "$default_plain"
                echo "  (default accepted)"
                return 0
            fi
        else
            read -r -s -p "$prompt (empty = no login): " p1
            echo
            if [[ -z "$p1" ]]; then
                printf -v "$__out" '%s' ""
                echo "  (empty — no login)"
                return 0
            fi
        fi
        read -r -s -p "  retype to confirm: " p2
        echo
        if [[ "$p1" == "$p2" ]]; then
            hash_password "$__out" "$p1"
            return 0
        fi
        echo "  passwords differ; try again."
    done
}

# detect_secure_boot prints "enabled" | "disabled" | "unknown" to stdout.
# The EFI_GLOBAL_VARIABLE "SecureBoot" GUID is fixed by the UEFI spec.
# The efivar file's last byte is the boolean (preceded by 4 bytes of
# EFI attribute header). Used by the LUKS_TPM prompt to warn when SB
# is off — PCR 7 binding still works in that case but the threat model
# collapses to "encryption at rest against an SSD-only thief".
detect_secure_boot() {
    local f="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    if [[ ! -e "$f" ]]; then
        echo "unknown"
        return 0
    fi
    local last_byte
    last_byte=$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}')
    case "$last_byte" in
        1) echo "enabled" ;;
        0) echo "disabled" ;;
        *) echo "unknown" ;;
    esac
}

# ask_luks_passphrase OUTVAR "prompt"
#   Like ask_password, but does NOT hash the result — the LUKS
#   passphrase needs to be handed verbatim to disko (for luksFormat)
#   and to systemd-cryptenroll (for TPM enrollment). Reads
#   EGGHEAD_LUKS_PASSPHRASE if present; otherwise prompts twice with
#   no echo. --non-interactive without the env var hard-fails.
ask_luks_passphrase() {
    local __out="$1" prompt="$2"
    local env_plain="EGGHEAD_LUKS_PASSPHRASE"
    if [[ -n "${!env_plain+x}" ]]; then
        printf -v "$__out" '%s' "${!env_plain}"
        echo ">> $prompt: (from \$$env_plain)" >&2
        return 0
    fi
    if (( NONINTERACTIVE )); then
        echo "error: --non-interactive requires \$$env_plain when LUKS=yes" >&2
        exit 2
    fi
    local p1 p2
    while true; do
        read -r -s -p "$prompt: " p1
        echo
        if [[ -z "$p1" ]]; then
            echo "  passphrase cannot be empty for LUKS"
            continue
        fi
        read -r -s -p "  retype to confirm: " p2
        echo
        if [[ "$p1" == "$p2" ]]; then
            printf -v "$__out" '%s' "$p1"
            return 0
        fi
        echo "  passphrases differ; try again."
    done
}

# ─── role table ─────────────────────────────────────────────────
# Each role presets:
#   layout: bare-metal | vm
#   features: space-separated feature module names. Names MUST match
#     filenames in flake-modules/<name>.nix verbatim (that's what the
#     generated bridge will reference as
#     config.flake.modules.nixos.<name>).
#   hm_profile: default HM bundle for the primary user (base | dev |
#     desktop | kid).
#   disk_hint: a sensible default disk path for the role.
#   unattended: whether to bake in auto-upgrade + hm-auto-upgrade
#     (server-class hosts; nixos-clone is always on regardless).
#
# Adding a role: append to role_names + define a role_<name>_* set of
# vars; mirror the case statement in emit_bridge().
role_names="bare-metal-laptop bare-metal-desktop vm-headless vm-desktop"

# Common feature subset every host gets: minimum-viable bootable
# NixOS box with this flake's conventions (nix-settings + flakes,
# networking, declared users, openssh for fallback access, the bare
# system-utils set, system locale, system fonts for kmscon/tty, boot
# loader policy, HM bootstrap-on-first-boot).
COMMON_FEATURES="nix-settings networking openssh users system-utils locale fonts boot home-manager-bootstrap"

# Feature names that live in `flake.modules.homeManager.*` instead
# of `flake.modules.nixos.*`. Listed in the wizard's catalog so they
# show up alongside the NixOS features, but emit_bridge routes them
# into every user's HM `imports` list instead of the host's NixOS
# imports list. Keep in sync with packages/egghead/src/features.ts.
HM_ONLY_FEATURES="kicad freecad firefox"

role_bare_metal_laptop_layout="bare-metal"
role_bare_metal_laptop_features="battery biometrics face-unlock bluetooth audio gpu power niri quickshell hardware-hacking file-manager login-ly kicad freecad firefox"
role_bare_metal_laptop_hm="desktop"
role_bare_metal_laptop_disk="/dev/nvme0n1"
role_bare_metal_laptop_unattended="no"

role_bare_metal_desktop_layout="bare-metal"
role_bare_metal_desktop_features="bluetooth audio gpu power niri quickshell hardware-hacking file-manager login-ly kicad freecad firefox"
role_bare_metal_desktop_hm="desktop"
role_bare_metal_desktop_disk="/dev/sda"
role_bare_metal_desktop_unattended="no"

role_vm_headless_layout="vm"
role_vm_headless_features=""
role_vm_headless_hm="dev"
role_vm_headless_disk="/dev/vda"
role_vm_headless_unattended="yes"

role_vm_desktop_layout="vm"
role_vm_desktop_features="audio gpu niri quickshell file-manager login-ly"
role_vm_desktop_hm="desktop"
role_vm_desktop_disk="/dev/vda"
role_vm_desktop_unattended="no"

role_lookup() {
    # role_lookup VAR ROLE FIELD
    #   VAR: bash var to set to the looked-up value
    #   ROLE: one of $role_names
    #   FIELD: layout | features | hm | disk | unattended
    local __out="$1" role="$2" field="$3"
    local key
    key="role_$(echo "$role" | tr '-' '_')_${field}"
    if [[ -z "${!key+x}" ]]; then
        echo "error: unknown role/field: $role / $field" >&2
        return 1
    fi
    printf -v "$__out" '%s' "${!key}"
}

# ─── disk discovery ───
list_disks() {
    if command -v lsblk >/dev/null 2>&1; then
        # NAME without partitions; whole disks only.
        lsblk -dnpo NAME,SIZE,MODEL 2>/dev/null || true
    else
        echo "  (lsblk not available)"
    fi
}

# RAM-rounded-up swap size for hibernate. Returns "<N>G" where N is
# the installed RAM size in GiB, rounded UP so hibernate (which needs
# swap >= RAM) clears with no margin disputes. On a 31 GiB host this
# returns "32G"; on 7.6 GiB it returns "8G". Returns "0G" if
# /proc/meminfo is unreadable (the wizard then prompts and the user
# can pick the right value or set "" to skip swap entirely).
default_swap_size() {
    local kib
    kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")
    if [[ -z "$kib" ]]; then
        echo "0G"; return
    fi
    # Round up to whole GiB. (kib + (1Gi-1)) / 1Gi.
    local gib=$(( (kib + 1048575) / 1048576 ))
    echo "${gib}G"
}

# ─── clone the flake ───
do_clone() {
    if (( ! DO_CLONE )); then
        echo ">> --no-clone: using existing checkout at $WORKDIR"
        if [[ ! -f "$WORKDIR/flake.nix" ]]; then
            echo "error: $WORKDIR has no flake.nix" >&2
            exit 3
        fi
        return 0
    fi

    if [[ -e "$WORKDIR" ]]; then
        echo "error: $WORKDIR already exists; refusing to overwrite." >&2
        echo "       remove it first, or pass --workdir <other-path>." >&2
        exit 3
    fi

    echo ">> cloning $EGGHEAD_FLAKE_URL (ref $EGGHEAD_FLAKE_REF) into $WORKDIR …"
    # Use plain `clone` + `checkout` instead of `clone --branch <ref>`
    # because --branch only accepts branch / tag names; the wizard's
    # default ref is the SHA the wizard was built from (so it matches
    # the wizard's source exactly), which --branch would reject.
    git clone "$EGGHEAD_FLAKE_URL" "$WORKDIR"
    git -C "$WORKDIR" checkout --detach "$EGGHEAD_FLAKE_REF"
}

# ─── bridge file generator ─────────────────────────────────────
# Inputs (globals): HOSTNAME, PRIMARY_USER, PRIMARY_FULLNAME,
#   EXTRA_USERS_JSON (jq-parseable array of {login, fullname,
#     profile, hashedPassword}), ROLE, DISKO_LAYOUT,
#   DISK, GPU_DRIVER, TZ, LOCALE, KEYMAP, FEATURES (space-separated),
#   STATE_VERSION, UNATTENDED.
#
# Output: writes the bridge file to $WORKDIR/flake-modules/hosts/$HOSTNAME.nix
emit_bridge() {
    local out="$WORKDIR/flake-modules/hosts/$HOSTNAME.nix"
    local f
    local imports_block=""
    # Translate yes/no → Nix bool for the diskoLayouts factory call.
    local LUKS_NIX="false"
    [[ "$LUKS" == "yes" ]] && LUKS_NIX="true"
    # Translate swap size → optional Nix factory arg. Empty SWAP_SIZE
    # (or "" / "0" / "none") means "no swap"; the disko factory
    # treats `swapSize = null` as "no swap partition", and we get
    # there by simply omitting the arg from the factory call (the
    # factory's default IS null).
    local SWAP_SIZE_NIX_LINE=""
    case "${SWAP_SIZE:-}" in
        ""|0|0G|none) ;;  # leave SWAP_SIZE_NIX_LINE empty
        *) SWAP_SIZE_NIX_LINE=$'\n'"          swapSize = \"$SWAP_SIZE\";" ;;
    esac
    # Always-on substrate.
    for f in $COMMON_FEATURES; do
        imports_block+="        config.flake.modules.nixos.$f"$'\n'
    done
    # First-boot hwconfig amend service (declared by
    # flake-modules/egghead.nix). Self-disables via sentinel; safe to
    # leave in long-term.
    imports_block+="        config.flake.modules.nixos.egghead-amend"$'\n'
    # Per-user clone of this flake into /home/<user>/nixos. The
    # unit's ConditionPathExists guards against re-cloning, so it's
    # a no-op once each user has a checkout — safe on every host,
    # not just unattended. egghead-amend's inline clone is the
    # immediate-first-boot fast path; nixos-clone is the persistent
    # retry mechanism (it re-arms on every boot until the clone
    # exists).
    imports_block+="        config.flake.modules.nixos.nixos-clone"$'\n'
    # Role-driven add-ons. Skip any HM-class feature names — those
    # are emitted as extra HM imports per-user below instead.
    for f in $FEATURES; do
        case " $HM_ONLY_FEATURES " in
            *" $f "*) continue ;;
        esac
        imports_block+="        config.flake.modules.nixos.$f"$'\n'
    done

    # Per-user extra HM imports: append the HM-class features (kicad,
    # …) to whichever bundle each user picks. Same set goes to every
    # user on the host; if you want per-user differentiation, edit the
    # bridge after install.
    local hm_extras=""
    for f in $FEATURES; do
        case " $HM_ONLY_FEATURES " in
            *" $f "*)
                hm_extras+="        config.flake.modules.homeManager.$f"$'\n'
                ;;
        esac
    done
    # Unattended add-ons.
    if [[ "$UNATTENDED" == "yes" ]]; then
        imports_block+="        config.flake.modules.nixos.auto-upgrade"$'\n'
        imports_block+="        config.flake.modules.nixos.hm-auto-upgrade"$'\n'
    fi

    # Battery block — only when battery feature is in the list.
    local battery_block=""
    if echo " $FEATURES " | grep -q ' battery '; then
        battery_block=$(cat <<'BATEOF'

      # Battery thresholds + hibernate critical-action. Tune per-host
      # once you know the chassis behaviour. Swap (for hibernate) is
      # provisioned by the disko factory above (swapSize arg) as its
      # own GPT partition, so resumeDevice + hibernate-resume just
      # work — no per-host resume_offset to maintain.
      battery = {
        chargeStopThreshold = 80;
        chargeStartThreshold = 75;
        criticalPercent = 10;
        criticalAction = "Hibernate";
        powerSaverPercent = 40;
      };
BATEOF
)
    fi

    # gpu block — only when gpu feature is in the list.
    local gpu_block=""
    if echo " $FEATURES " | grep -q ' gpu '; then
        gpu_block="
      # GPU driver picked by egghead at install time. Adjust if
      # follow-up lspci reveals a hybrid / non-default device.
      gpu.driver = \"$GPU_DRIVER\";"
    fi

    # LUKS+TPM auto-unlock block — only when both LUKS and TPM are
    # enabled. systemd-stage-1 initrd is required by systemd-cryptsetup's
    # TPM2 unlock path; it also tends to enumerate Surface Aggregator /
    # modern HID better than the legacy script-stage-1, which matters
    # for the keyboard-in-initrd story on Surface laptops if you ever
    # need to fall back to typing the passphrase. The passphrase keyslot
    # remains as a fallback in case PCR 7 changes (Secure Boot toggled,
    # firmware re-keyed, etc.); host-setup.sh enrolled the TPM2 keyslot
    # at install time bound to PCR 7.
    local luks_tpm_block=""
    if [[ "$LUKS_TPM" == "yes" ]]; then
        luks_tpm_block=$(cat <<'TPMEOF'

      boot.initrd.systemd.enable = true;
      boot.initrd.luks.devices.cryptroot.crypttabExtraOpts = [ "tpm2-device=auto" ];
TPMEOF
)
    fi

    # Recovery: root account. Hashed password lives in
    # `users.users.root.initialHashedPassword` (safe to commit).
    # Skipped entirely if the operator left the root password empty.
    local root_block=""
    if [[ -n "$ROOT_HASHED_PASSWORD" ]]; then
        # Escape backslash + double-quote for the Nix string literal.
        local _rh=${ROOT_HASHED_PASSWORD//\\/\\\\}
        _rh=${_rh//\"/\\\"}
        root_block="        root = {"$'\n'
        root_block+="          initialHashedPassword = \"$_rh\";"$'\n'
        root_block+="        };"$'\n'
    fi

    # Helper: emit the `users.users.<login>` attr block. Captures the
    # common fields once so primary + extras stay in lock-step.
    emit_user_attr() {
        local login="$1" fullname="$2" hashed="$3" extra_groups="$4"
        local _h=${hashed//\\/\\\\}
        _h=${_h//\"/\\\"}
        local _f=${fullname//\\/\\\\}
        _f=${_f//\"/\\\"}
        local out=""
        out+="        $login = {"$'\n'
        out+="          isNormalUser = true;"$'\n'
        out+="          description = \"$_f\";"$'\n'
        out+="          extraGroups = [ $extra_groups ];"$'\n'
        out+="          shell = hmPkgs.zsh;"$'\n'
        if [[ -n "$_h" ]]; then
            out+="          initialHashedPassword = \"$_h\";"$'\n'
        else
            out+="          # Empty initialHashedPassword = no login. Set a"$'\n'
            out+="          # password manually (\`sudo passwd $login\`) before"$'\n'
            out+="          # first use."$'\n'
            out+="          initialHashedPassword = \"\";"$'\n'
        fi
        out+="        };"$'\n'
        printf '%s' "$out"
    }

    # Build users.users attrset entries. Primary first, then extras
    # parsed from EXTRA_USERS_JSON.
    local users_block=""
    users_block+=$(emit_user_attr "$PRIMARY_USER" "$PRIMARY_FULLNAME" \
        "$PRIMARY_HASHED_PASSWORD" \
        '"wheel" "networkmanager" "video" "audio" "input"')
    users_block+="$root_block"

    # Helper: build the `imports = …` line(s) for an HM user. The
    # bundle is always the first list; HM-class features (hm_extras)
    # are appended via `++ [ … ]` so the per-host opt-in stays
    # visually grouped in the bridge file.
    emit_hm_imports() {
        local bundle="$1"
        if [[ -n "$hm_extras" ]]; then
            printf '      imports = config.flake.lib.bundles.homeManager.%s ++ [\n' "$bundle"
            # hm_extras already has 8-space indent; HM block wants 8.
            printf '%s' "$hm_extras"
            printf '      ];\n'
        else
            printf '      imports = config.flake.lib.bundles.homeManager.%s;\n' "$bundle"
        fi
    }

    # HM configurations: primary always present.
    local hm_block=""
    hm_block+="  configurations.homeManager.\"${PRIMARY_USER}@${HOSTNAME}\" = {"$'\n'
    hm_block+="    pkgs = hmPkgs;"$'\n'
    hm_block+="    module = {"$'\n'
    hm_block+=$(emit_hm_imports "$PRIMARY_HM")$'\n'
    hm_block+="      programs.home-manager.enable = true;"$'\n'
    hm_block+="      home.username = \"$PRIMARY_USER\";"$'\n'
    hm_block+="      home.homeDirectory = \"/home/$PRIMARY_USER\";"$'\n'
    hm_block+="      home.stateVersion = stateVersion;"$'\n'
    hm_block+="      home.sessionVariables = { EDITOR = \"vim\"; VISUAL = \"vim\"; };"$'\n'
    hm_block+="    };"$'\n'
    hm_block+="  };"$'\n'

    # Extra users from JSON. Each element must have login/fullname/
    # profile/hashedPassword. `EXTRA_USERS_JSON` is populated by
    # collect_extra_users() either from EGGHEAD_EXTRA_USERS_JSON,
    # from an interactive loop, or as "[]".
    local n i login fullname profile hashed
    n=$(jq 'length' <<< "$EXTRA_USERS_JSON")
    for (( i = 0; i < n; i++ )); do
        login=$(jq -r ".[$i].login"           <<< "$EXTRA_USERS_JSON")
        fullname=$(jq -r ".[$i].fullname"     <<< "$EXTRA_USERS_JSON")
        profile=$(jq -r ".[$i].profile"       <<< "$EXTRA_USERS_JSON")
        hashed=$(jq -r ".[$i].hashedPassword" <<< "$EXTRA_USERS_JSON")
        users_block+=$(emit_user_attr "$login" "$fullname" "$hashed" \
            '"video" "audio" "input" "networkmanager"')

        hm_block+="  configurations.homeManager.\"${login}@${HOSTNAME}\" = {"$'\n'
        hm_block+="    pkgs = hmPkgs;"$'\n'
        hm_block+="    module = {"$'\n'
        hm_block+=$(emit_hm_imports "$profile")$'\n'
        hm_block+="      programs.home-manager.enable = true;"$'\n'
        hm_block+="      home.username = \"$login\";"$'\n'
        hm_block+="      home.homeDirectory = \"/home/$login\";"$'\n'
        hm_block+="      home.stateVersion = stateVersion;"$'\n'
        hm_block+="    };"$'\n'
        hm_block+="  };"$'\n'
    done

    # SSH recovery posture. Only when a root password is set:
    # allow PasswordAuthentication + root login so the operator can
    # `ssh root@host` from the LAN when X/HM is broken. Override
    # post-install if you want a stricter policy.
    local ssh_recovery_block=""
    if [[ -n "$ROOT_HASHED_PASSWORD" ]]; then
        ssh_recovery_block=$'\n'"      # SSH recovery posture emitted by egghead. Tighten"$'\n'
        ssh_recovery_block+="      # post-install once the host is healthy."$'\n'
        ssh_recovery_block+="      services.openssh.settings = {"$'\n'
        ssh_recovery_block+="        PasswordAuthentication = true;"$'\n'
        ssh_recovery_block+="        PermitRootLogin = \"yes\";"$'\n'
        ssh_recovery_block+="      };"$'\n'
    fi

    mkdir -p "$(dirname "$out")"
    cat > "$out" <<EOF
# $HOSTNAME — generated by egghead on $(date -u +%Y-%m-%dT%H:%M:%SZ).
#
# Role template: $ROLE
# Disko layout : $DISKO_LAYOUT (disk = $DISK, luks = $LUKS_NIX)
#
# This file was generated by scripts/egghead.sh. Nothing here is
# sacred — edit by hand once the host is up. The wizard only knows
# how to write the minimal viable shape; per-host knobs (battery
# thresholds, audio autoloads, gpu driver, multi-battery names, etc.)
# should be tuned manually.
#
# Retire when: this host is decommissioned. Hand-rewrite this file
# (or delete it) once the host's needs diverge from what egghead
# emits.
{ lib, config, ... }:
let
  hostName = "$HOSTNAME";
  user = "$PRIMARY_USER";
  system = "x86_64-linux";
  stateVersion = "$STATE_VERSION";

  hmPkgs = config.flake.lib.mkPkgs system;
in
{
  locale = {
    timezone = "$TZ";
    lang = "$LOCALE";
  };

  configurations.nixos.\${hostName} = {
    module = {
      imports = [
        ../../hosts/$HOSTNAME/hardware-configuration.nix
        # Declarative disk layout (see flake-modules/disko.nix and the
        # diskoLayouts.$DISKO_LAYOUT factory). Imports
        # inputs.disko.nixosModules.disko under the hood, which
        # synthesizes fileSystems + swapDevices from disko.devices.
        config.flake.modules.nixos.disko
        (config.flake.lib.diskoLayouts.$DISKO_LAYOUT {
          disk = "$DISK";
          luks = $LUKS_NIX;${SWAP_SIZE_NIX_LINE}
        })
$imports_block      ];

      networking.hostName = hostName;
      users.primary = user;
      console.keyMap = "$KEYMAP";
$gpu_block
$battery_block
$ssh_recovery_block$luks_tpm_block
      # mkDefault so hardware modules (nixos-hardware microsoft-
      # surface-*, lenovo-thinkpad-*, etc.) that ship their own
      # patched kernel can override without an mkForce.
      boot.kernelPackages = lib.mkDefault hmPkgs.linuxPackages_latest;

      users.users = {
$users_block      };

      environment.systemPackages = with hmPkgs; [
        git
        vim
        curl
        wget
      ];

      system.stateVersion = stateVersion;
    };
  };

$hm_block}
EOF
    echo ">> wrote $out"
}

# ─── placeholder hwconfig ──────────────────────────────────────
# When --no-install, we don't run nixos-generate-config (probably no
# block device anyway). Emit the placeholder shape so `nix flake check
# --impure` keeps passing and the generated bridge is at least
# importable.
emit_placeholder_hwconfig() {
    local out="$WORKDIR/hosts/$HOSTNAME/hardware-configuration.nix"
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<'EOF'
# Placeholder hardware-configuration.nix written by egghead.
#
# This file is replaced by `nixos-generate-config --no-filesystems
# --show-hardware-config` during the next `scripts/host-setup.sh
# --install` on real hardware. Until then, building this host's
# toplevel asserts unless NIXOS_ALLOW_PLACEHOLDER=1 is in the env —
# this keeps a `sudo nixos-rebuild switch` from accidentally
# activating an unbootable config.
{ config, lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  assertions = [{
    assertion = builtins.getEnv "NIXOS_ALLOW_PLACEHOLDER" == "1";
    message = ''
      This host has a placeholder hardware-configuration.nix written
      by egghead. Run `sudo nixos-generate-config --no-filesystems
      --show-hardware-config > hosts/<name>/hardware-configuration.nix`
      on the real hardware (or `scripts/host-setup.sh --install
      <name>`), or set NIXOS_ALLOW_PLACEHOLDER=1 for smoke builds.
    '';
  }];

  # Default to x86_64 so smoke builds work on a dev machine. Override
  # in the regenerated file if the actual host is aarch64.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
EOF
    echo ">> wrote placeholder $out"
}

# ─── generate real hwconfig (only when DO_INSTALL=1, i.e. we're on
# the live installer ISO) ─────────────────────────────────────────
emit_real_hwconfig() {
    local out="$WORKDIR/hosts/$HOSTNAME/hardware-configuration.nix"
    mkdir -p "$(dirname "$out")"
    if ! command -v nixos-generate-config >/dev/null 2>&1; then
        echo "error: nixos-generate-config not on PATH" >&2
        echo "       (egghead expects to run from a NixOS installer ISO)." >&2
        exit 3
    fi
    echo ">> generating $out via nixos-generate-config --no-filesystems …"
    # --no-filesystems is mandatory: disko owns fileSystems.* and
    # swapDevices. A generated fileSystems.\"/\" would collide with the
    # one disko produces.
    nixos-generate-config --no-filesystems --show-hardware-config > "$out"
}

# ─── git add + commit ──────────────────────────────────────────
do_commit() {
    (
        cd "$WORKDIR"
        git add "flake-modules/hosts/$HOSTNAME.nix" \
                "hosts/$HOSTNAME/hardware-configuration.nix"
        # Configure a throwaway identity if the cloned repo has none —
        # the installer ISO has no global git config.
        if ! git config user.email >/dev/null 2>&1; then
            git config user.email "egghead@local"
            git config user.name  "egghead"
        fi
        git commit -m "egghead: install $HOSTNAME" \
                   -m "Role: $ROLE; disko layout: $DISKO_LAYOUT; disk: $DISK." \
                   -m "Generated by scripts/egghead.sh — edit by hand to taste."
    )
    echo ">> committed bridge + hwconfig"
}

# ─── hand off to host-setup.sh ─────────────────────────────────
do_install() {
    if (( ! DO_INSTALL )); then
        echo
        echo ">> --no-install: wizard finished without touching disks."
        echo "   Generated checkout at: $WORKDIR"
        echo "   Inspect with:  (cd $WORKDIR && git log -1 --stat)"
        echo "   To install for real later:"
        echo "     sudo $WORKDIR/scripts/host-setup.sh --install $HOSTNAME --no-regen-hwconfig"
        return 0
    fi

    local setup="$WORKDIR/scripts/host-setup.sh"
    if [[ ! -x "$setup" ]]; then
        echo "error: $setup is missing or not executable" >&2
        exit 3
    fi

    # If LUKS is enabled, materialize the passphrase as a tmpfs key
    # file so disko (formats + opens non-interactively) and, when
    # TPM=yes, systemd-cryptenroll (seeds the TPM2 keyslot) can both
    # read it without re-prompting the operator. /run is tmpfs on the
    # live ISO so nothing touches disk. host-setup.sh installs an
    # EXIT trap that shreds the file even on abort. Both EGGHEAD_LUKS_*
    # envs are added to sudo's --preserve-env list so the elevated
    # child sees them.
    local preserve_env="NIX_EXTRA_OPTS,NIX_SUBSTITUTER_OPTS"
    if [[ "$LUKS" == "yes" ]]; then
        local keyfile="/run/egghead-luks.key"
        install -m 600 /dev/null "$keyfile"
        printf '%s' "$LUKS_PASSPHRASE" > "$keyfile"
        export EGGHEAD_LUKS_PASSWORD_FILE="$keyfile"
        export EGGHEAD_LUKS_TPM
        preserve_env+=",EGGHEAD_LUKS_PASSWORD_FILE,EGGHEAD_LUKS_TPM"
    fi

    echo
    echo ">> handing off to: sudo $setup --install $HOSTNAME --no-regen-hwconfig --disk $DISK"
    exec sudo --preserve-env="$preserve_env" \
        "$setup" --install "$HOSTNAME" --no-regen-hwconfig --disk "$DISK"
}

# ─── extras collector ──────────────────────────────────────────
# Sets EXTRA_USERS_JSON (jq-parseable array of objects with
# {login, fullname, profile, hashedPassword}). Sources, in order:
#
#   1. EGGHEAD_EXTRA_USERS_JSON env var (TUI fills it). Each entry
#      may carry either `password` (plain) or `hashedPassword`
#      (yescrypt). Plain passwords are hashed here so the rest of
#      the script only ever sees hashes.
#   2. --non-interactive without env => empty array.
#   3. Interactive: loop "add another user?" until no. Per user,
#      collect login, fullname, profile choice, password (no echo,
#      twice). Empty password = no login (matches primary's behaviour).
collect_extra_users() {
    if [[ -n "${EGGHEAD_EXTRA_USERS_JSON+x}" ]]; then
        local raw="${EGGHEAD_EXTRA_USERS_JSON}"
        [[ -z "$raw" ]] && raw="[]"
        if ! jq -e 'type == "array"' <<< "$raw" >/dev/null 2>&1; then
            echo "error: \$EGGHEAD_EXTRA_USERS_JSON is not a JSON array" >&2
            exit 2
        fi
        # Normalize: hash any plain `password` into `hashedPassword`,
        # then drop the plain field so it never reaches a file.
        local n i obj plain normalized="[]"
        local hashed=""
        n=$(jq 'length' <<< "$raw")
        for (( i = 0; i < n; i++ )); do
            obj=$(jq -c ".[$i]" <<< "$raw")
            if jq -e 'has("hashedPassword")' <<< "$obj" >/dev/null; then
                : # already hashed; pass through
            elif jq -e 'has("password")' <<< "$obj" >/dev/null; then
                plain=$(jq -r '.password' <<< "$obj")
                hash_password hashed "$plain"
                obj=$(jq -c --arg h "$hashed" \
                    'del(.password) | .hashedPassword = $h' <<< "$obj")
            else
                obj=$(jq -c '.hashedPassword = ""' <<< "$obj")
            fi
            normalized=$(jq -c --argjson e "$obj" '. + [$e]' <<< "$normalized")
        done
        EXTRA_USERS_JSON="$normalized"
        echo ">> extra users: $(jq 'length' <<< "$EXTRA_USERS_JSON") configured (from \$EGGHEAD_EXTRA_USERS_JSON)" >&2
        return 0
    fi

    if (( NONINTERACTIVE )); then
        EXTRA_USERS_JSON="[]"
        return 0
    fi

    EXTRA_USERS_JSON="[]"
    echo
    echo "Extra users (besides $PRIMARY_USER). Each one gets a home"
    echo "directory + HM bundle. You'll be asked per user; leave the"
    echo "wizard's loop with 'n' when you're done."
    local add_more login fullname profile hashed
    while true; do
        read -r -p "add another user? (y/n) [n]: " add_more
        add_more="${add_more:-n}"
        case "$add_more" in
            n|N|no|NO) break ;;
            y|Y|yes|YES) ;;
            *) echo "  invalid: y or n"; continue ;;
        esac

        while true; do
            read -r -p "  login: " login
            if [[ "$login" =~ ^[a-z_][a-z0-9_-]*$ ]]; then break; fi
            echo "    bad linux username '$login'; must match [a-z_][a-z0-9_-]*"
        done
        read -r -p "  full name [$login]: " fullname
        fullname="${fullname:-$login}"
        while true; do
            read -r -p "  HM profile {base dev desktop kid} [kid]: " profile
            profile="${profile:-kid}"
            case "$profile" in
                base|dev|desktop|kid) break ;;
                *) echo "    invalid: must be one of base dev desktop kid" ;;
            esac
        done
        # Same two-prompt no-echo flow as ask_password, but inline so
        # we don't have to plumb a synthetic env-var name through.
        local p1 p2
        while true; do
            read -r -s -p "  password (empty = no login): " p1
            echo
            if [[ -z "$p1" ]]; then hashed=""; break; fi
            read -r -s -p "    retype to confirm: " p2
            echo
            if [[ "$p1" == "$p2" ]]; then
                hash_password hashed "$p1"
                break
            fi
            echo "    passwords differ; try again."
        done

        EXTRA_USERS_JSON=$(jq -c \
            --arg login "$login" \
            --arg fullname "$fullname" \
            --arg profile "$profile" \
            --arg hashed "$hashed" \
            '. + [{login: $login, fullname: $fullname, profile: $profile, hashedPassword: $hashed}]' \
            <<< "$EXTRA_USERS_JSON")
        echo "  added: $login ($fullname, hm=$profile)"
    done
}

# ─── main wizard ───────────────────────────────────────────────
main() {
    cat <<'EOF'
═══════════════════════════════════════════════════════════════════
 egghead — opinionated NixOS installer wizard
═══════════════════════════════════════════════════════════════════

  This wizard will write a new host bridge + hardware-configuration
  into a fresh checkout of the flake, commit it, then hand off to
  scripts/host-setup.sh for disko + nixos-install + home-manager.

  All answers are also accepted from EGGHEAD_* env vars; pass
  --non-interactive to fail-fast instead of prompting.

  Ctrl-C at any prompt to abort. Nothing is written until the final
  "proceed?" confirmation. Nothing is destructively partitioned
  until host-setup.sh's own YES prompt.

EOF

    echo "  flake source: $EGGHEAD_FLAKE_URL"
    echo "  flake ref:    $EGGHEAD_FLAKE_REF"
    echo "  workdir:      $WORKDIR"
    echo

    do_clone

    ask HOSTNAME "hostname" ""
    if ! [[ "$HOSTNAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
        echo "error: hostname must match [a-z][a-z0-9-]* (got '$HOSTNAME')" >&2
        exit 2
    fi
    if [[ -e "$WORKDIR/flake-modules/hosts/$HOSTNAME.nix" ]]; then
        echo "error: host '$HOSTNAME' already exists at flake-modules/hosts/$HOSTNAME.nix" >&2
        echo "       pick a different name or remove the existing bridge first." >&2
        exit 2
    fi

    ask_choice ROLE "role template" "bare-metal-laptop" "$role_names"
    role_lookup DISKO_LAYOUT  "$ROLE" "layout"
    role_lookup ROLE_FEATURES "$ROLE" "features"
    role_lookup ROLE_HM       "$ROLE" "hm"
    role_lookup ROLE_DISK     "$ROLE" "disk"
    role_lookup ROLE_UNATT    "$ROLE" "unattended"

    if (( ! NONINTERACTIVE )) && [[ -z "${EGGHEAD_DISK-}" ]]; then
        echo
        echo "Disks visible on this system:"
        list_disks | sed 's/^/  /'
        echo
    fi
    ask DISK "target disk (whole-disk path; WILL BE WIPED)" "$ROLE_DISK"

    # Swap partition size. Default = installed RAM rounded up to GiB
    # so hibernate works (kernel needs swap >= RAM). Empty / 0 / none
    # = no swap partition (and no hibernate).
    ask SWAP_SIZE "swap partition size (e.g. 32G; empty = no swap)" "$(default_swap_size)"

    ask PRIMARY_USER "primary user login" "p"
    if ! [[ "$PRIMARY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "error: bad linux username '$PRIMARY_USER'" >&2
        exit 2
    fi
    ask PRIMARY_FULLNAME "primary user full name" "$PRIMARY_USER"
    ask_choice PRIMARY_HM "primary HM profile" "$ROLE_HM" "base dev desktop kid"
    ask_password PRIMARY_HASHED_PASSWORD "primary user password" ""

    # Extras: prefer EGGHEAD_EXTRA_USERS_JSON (TUI fills this with
    # already-hashed passwords). Otherwise, interactively loop
    # add-another-user. --non-interactive with unset env = no extras.
    collect_extra_users

    ask FEATURES "feature toggles (space-separated)" "$ROLE_FEATURES"

    if echo " $FEATURES " | grep -q ' gpu '; then
        ask_choice GPU_DRIVER "gpu driver" "intel" "intel amd nvidia none"
    else
        GPU_DRIVER="none"
    fi

    ask TZ "timezone" "America/Los_Angeles"
    ask LOCALE "locale" "en_US.UTF-8"
    ask KEYMAP "console keymap" "us"
    ask STATE_VERSION "system.stateVersion" "$EGGHEAD_DEFAULT_STATE_VERSION"
    # LUKS full-disk encryption: wraps the root partition in a LUKS2
    # container. When LUKS=yes the wizard also collects a passphrase
    # (kept in tmpfs only) and offers TPM2 auto-unlock if /dev/tpmrm0
    # is present on the live ISO. host-setup.sh feeds the passphrase
    # to disko via a tmpfs key file and (when TPM=yes) enrolls a TPM2
    # keyslot bound to PCR 7 via systemd-cryptenroll right after disko
    # opens the container.
    ask_yesno LUKS "encrypt root partition with LUKS?" "no"
    if [[ "$LUKS" == "yes" ]]; then
        ask_luks_passphrase LUKS_PASSPHRASE "LUKS passphrase"
        local tpm_default="no"
        [[ -e /dev/tpmrm0 ]] && tpm_default="yes"
        local sb_state
        sb_state=$(detect_secure_boot)
        if [[ "$sb_state" == "disabled" ]]; then
            cat >&2 <<'WARNEOF'

  ⚠  Secure Boot is DISABLED on this host.
     TPM2 + PCR 7 unlock still works, but the security model is
     reduced to "encryption at rest against an SSD-only thief".
     An attacker who steals the whole laptop can boot any kernel
     and the TPM will release the disk key (PCR 7 measures
     SB-disabled state regardless of what OS boots).
     Acceptable for convenience; NOT acceptable if your threat
     model includes laptop theft.

WARNEOF
        elif [[ "$sb_state" == "unknown" ]]; then
            echo >&2
            echo "  note: could not read Secure Boot EFI variable; assuming UEFI defaults." >&2
        fi
        ask_yesno LUKS_TPM "auto-unlock with TPM2 at boot (passphrase remains as fallback)?" "$tpm_default"
    else
        LUKS_PASSPHRASE=""
        LUKS_TPM="no"
    fi

    # Recovery shell: a known root password from day one means a
    # broken X / display manager / HM activation never leaves you
    # locked out — drop to a TTY, or `ssh root@host` from another
    # box on the LAN. Stored hashed in the bridge.
    echo
    echo "Recovery: root password (hashed before commit; rotate on first boot)."
    echo "  Empty = no root login (use only if you have other recovery)."
    ask_password ROOT_HASHED_PASSWORD "root recovery password" "recovery"

    ask_yesno UNATTENDED "unattended host (auto-upgrade + hm-auto-upgrade)?" "$ROLE_UNATT"

    local extra_count
    extra_count=$(jq 'length' <<< "$EXTRA_USERS_JSON")

    echo
    echo "═══ Summary ═══"
    echo "  hostname     : $HOSTNAME"
    echo "  role         : $ROLE"
    echo "  disko layout : $DISKO_LAYOUT"
    echo "  disk         : $DISK"
    echo "  primary user : $PRIMARY_USER ($PRIMARY_FULLNAME, hm=$PRIMARY_HM)"
    if [[ -n "$PRIMARY_HASHED_PASSWORD" ]]; then
        echo "  primary pw   : (set)"
    else
        echo "  primary pw   : (unset — no login)"
    fi
    if (( extra_count > 0 )); then
        echo "  extra users  : $extra_count configured"
        local _i _login _profile
        for (( _i = 0; _i < extra_count; _i++ )); do
            _login=$(jq -r ".[$_i].login"   <<< "$EXTRA_USERS_JSON")
            _profile=$(jq -r ".[$_i].profile" <<< "$EXTRA_USERS_JSON")
            echo "    - $_login (hm=$_profile)"
        done
    else
        echo "  extra users  : (none)"
    fi
    echo "  features     : $COMMON_FEATURES + $FEATURES"
    echo "  unattended   : $UNATTENDED"
    echo "  LUKS         : $LUKS"
    if [[ "$LUKS" == "yes" ]]; then
        echo "  LUKS passphrase : (set, kept in tmpfs only)"
        echo "  LUKS TPM unlock : $LUKS_TPM"
    fi
    if [[ -n "$ROOT_HASHED_PASSWORD" ]]; then
        echo "  root pw      : (set)"
    else
        echo "  root pw      : (unset — no root login)"
    fi
    echo "  gpu          : $GPU_DRIVER"
    echo "  timezone     : $TZ"
    echo "  locale       : $LOCALE"
    echo "  keymap       : $KEYMAP"
    echo "  stateVersion : $STATE_VERSION"
    echo

    local PROCEED=""
    ask_yesno PROCEED "proceed to write files + commit?" "yes"
    if [[ "$PROCEED" != "yes" ]]; then
        echo "aborted (no files written)."
        exit 1
    fi

    emit_bridge
    if (( DO_INSTALL )); then
        emit_real_hwconfig
    else
        emit_placeholder_hwconfig
    fi
    do_commit
    do_install
}

main "$@"
