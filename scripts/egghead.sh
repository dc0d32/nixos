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
      4. primary user         (EGGHEAD_PRIMARY_USER)
      5. primary full name    (EGGHEAD_PRIMARY_FULLNAME)
      6. additional users     (EGGHEAD_EXTRA_USERS, semicolon-
                                separated tuples
                                "login:fullname:profile")
      7. feature toggles      (EGGHEAD_FEATURES, space-separated
                                module names; defaults from role)
      8. gpu driver           (EGGHEAD_GPU_DRIVER: intel|amd|nvidia|
                                none)
      9. timezone             (EGGHEAD_TZ, default America/Los_Angeles)
     10. locale               (EGGHEAD_LOCALE, default en_US.UTF-8)
     11. keymap               (EGGHEAD_KEYMAP, default us)
     12. LUKS full-disk       (EGGHEAD_LUKS: yes|no, default no)
                                encryption
     13. root password        (EGGHEAD_ROOT_PASSWORD; default
                                'recovery'. Empty = no root login.
                                Plain text; rotate on first boot.
                                Acts as console + SSH recovery if
                                graphics break.)

    HM profiles per user: base | dev | desktop | kid (maps to bundles
    in flake-modules/bundles/).

EXAMPLES:
    # Fully interactive from the installer ISO
    nix run github:dc0d32/nixos#egghead

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
#   unattended: whether to bake in auto-upgrade + nixos-clone +
#     hm-auto-upgrade (server-class hosts).
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

role_bare_metal_laptop_layout="bare-metal"
role_bare_metal_laptop_features="battery biometrics bluetooth audio gpu power niri quickshell hardware-hacking file-manager login-ly"
role_bare_metal_laptop_hm="desktop"
role_bare_metal_laptop_disk="/dev/nvme0n1"
role_bare_metal_laptop_unattended="no"

role_bare_metal_desktop_layout="bare-metal"
role_bare_metal_desktop_features="bluetooth audio gpu power niri quickshell hardware-hacking file-manager login-ly"
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
    git clone --branch "$EGGHEAD_FLAKE_REF" "$EGGHEAD_FLAKE_URL" "$WORKDIR"
}

# ─── bridge file generator ─────────────────────────────────────
# Inputs (globals): HOSTNAME, PRIMARY_USER, PRIMARY_FULLNAME,
#   EXTRA_USERS (raw semicolon-separated tuples), ROLE, DISKO_LAYOUT,
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
    # Always-on substrate.
    for f in $COMMON_FEATURES; do
        imports_block+="        config.flake.modules.nixos.$f"$'\n'
    done
    # First-boot hwconfig amend service (declared by
    # flake-modules/egghead.nix). Self-disables via sentinel; safe to
    # leave in long-term.
    imports_block+="        config.flake.modules.nixos.egghead-amend"$'\n'
    # Role-driven add-ons.
    for f in $FEATURES; do
        imports_block+="        config.flake.modules.nixos.$f"$'\n'
    done
    # Unattended add-ons.
    if [[ "$UNATTENDED" == "yes" ]]; then
        imports_block+="        config.flake.modules.nixos.auto-upgrade"$'\n'
        imports_block+="        config.flake.modules.nixos.nixos-clone"$'\n'
        imports_block+="        config.flake.modules.nixos.hm-auto-upgrade"$'\n'
    fi

    # Battery block — only when battery feature is in the list.
    local battery_block=""
    if echo " $FEATURES " | grep -q ' battery '; then
        battery_block=$(cat <<'BATEOF'

      # Battery thresholds + hibernate swap. Tune per-host once you
      # know the chassis behaviour. resumeDevice defaults to the btrfs
      # root captured in hardware-configuration.nix.
      battery = {
        chargeStopThreshold = 80;
        chargeStartThreshold = 75;
        criticalPercent = 10;
        criticalAction = "Hibernate";
        powerSaverPercent = 40;
        swapSizeGiB = 32;
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

    # Recovery: root password only. Set in the bridge as
    # `users.users.root.initialPassword`. Skipped entirely if the
    # operator left it empty.
    local root_block=""
    if [[ -n "$ROOT_PASSWORD" ]]; then
        local _rp=${ROOT_PASSWORD//\\/\\\\}
        _rp=${_rp//\"/\\\"}
        root_block="        root = {"$'\n'
        root_block+="          initialPassword = \"$_rp\";"$'\n'
        root_block+="        };"$'\n'
    fi

    # Build users.users attrset entries.
    local users_block=""
    users_block+="        $PRIMARY_USER = {"$'\n'
    users_block+="          isNormalUser = true;"$'\n'
    users_block+="          description = \"$PRIMARY_FULLNAME\";"$'\n'
    users_block+="          extraGroups = [ \"wheel\" \"networkmanager\" \"video\" \"audio\" \"input\" ];"$'\n'
    users_block+="          shell = hmPkgs.zsh;"$'\n'
    users_block+="          initialPassword = \"changeme\";"$'\n'
    users_block+="        };"$'\n'
    users_block+="$root_block"

    # HM configurations: primary always present.
    local hm_block=""
    hm_block+="  configurations.homeManager.\"${PRIMARY_USER}@${HOSTNAME}\" = {"$'\n'
    hm_block+="    pkgs = hmPkgs;"$'\n'
    hm_block+="    module = {"$'\n'
    hm_block+="      imports = config.flake.lib.bundles.homeManager.$PRIMARY_HM;"$'\n'
    hm_block+="      programs.home-manager.enable = true;"$'\n'
    hm_block+="      home.username = \"$PRIMARY_USER\";"$'\n'
    hm_block+="      home.homeDirectory = \"/home/$PRIMARY_USER\";"$'\n'
    hm_block+="      home.stateVersion = stateVersion;"$'\n'
    hm_block+="      home.sessionVariables = { EDITOR = \"vim\"; VISUAL = \"vim\"; };"$'\n'
    hm_block+="    };"$'\n'
    hm_block+="  };"$'\n'

    # Extra users (each tuple "login:fullname:profile").
    local raw u login fullname profile
    if [[ -n "$EXTRA_USERS" ]]; then
        IFS=';' read -r -a tuples <<< "$EXTRA_USERS"
        for raw in "${tuples[@]}"; do
            [[ -z "$raw" ]] && continue
            login="${raw%%:*}"; rest="${raw#*:}"
            fullname="${rest%%:*}"; profile="${rest##*:}"
            users_block+="        $login = {"$'\n'
            users_block+="          isNormalUser = true;"$'\n'
            users_block+="          description = \"$fullname\";"$'\n'
            users_block+="          extraGroups = [ \"video\" \"audio\" \"input\" \"networkmanager\" ];"$'\n'
            users_block+="          shell = hmPkgs.zsh;"$'\n'
            users_block+="          initialPassword = \"changeme\";"$'\n'
            users_block+="        };"$'\n'

            hm_block+="  configurations.homeManager.\"${login}@${HOSTNAME}\" = {"$'\n'
            hm_block+="    pkgs = hmPkgs;"$'\n'
            hm_block+="    module = {"$'\n'
            hm_block+="      imports = config.flake.lib.bundles.homeManager.$profile;"$'\n'
            hm_block+="      programs.home-manager.enable = true;"$'\n'
            hm_block+="      home.username = \"$login\";"$'\n'
            hm_block+="      home.homeDirectory = \"/home/$login\";"$'\n'
            hm_block+="      home.stateVersion = stateVersion;"$'\n'
            hm_block+="    };"$'\n'
            hm_block+="  };"$'\n'
        done
    fi

    # SSH recovery posture. Only when a root password is set:
    # allow PasswordAuthentication + root login so the operator can
    # `ssh root@host` from the LAN when X/HM is broken. Override
    # post-install if you want a stricter policy.
    local ssh_recovery_block=""
    if [[ -n "$ROOT_PASSWORD" ]]; then
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
# thresholds, audio autoloads, gpu driver, multi-battery names,
# resume_offset injection, etc.) should be tuned manually.
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
          luks = $LUKS_NIX;
        })
$imports_block      ];

      networking.hostName = hostName;
      users.primary = user;
      console.keyMap = "$KEYMAP";
$gpu_block
$battery_block
$ssh_recovery_block
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
    echo
    echo ">> handing off to: sudo $setup --install $HOSTNAME --no-regen-hwconfig --disk $DISK"
    exec sudo --preserve-env=NIX_EXTRA_OPTS,NIX_SUBSTITUTER_OPTS \
        "$setup" --install "$HOSTNAME" --no-regen-hwconfig --disk "$DISK"
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

    ask PRIMARY_USER "primary user login" "p"
    if ! [[ "$PRIMARY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "error: bad linux username '$PRIMARY_USER'" >&2
        exit 2
    fi
    ask PRIMARY_FULLNAME "primary user full name" "$PRIMARY_USER"
    ask_choice PRIMARY_HM "primary HM profile" "$ROLE_HM" "base dev desktop kid"

    echo
    echo "Extra users (semicolon-separated tuples \"login:fullname:profile\")."
    echo "  profile ∈ { base, dev, desktop, kid }. Leave empty for none."
    echo "  Example:  m:M:kid;s:S:kid"
    ask EXTRA_USERS "extra users" ""

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
    # container. disko's install-time askpass prompts the operator for
    # the passphrase interactively; no key material reaches the nix
    # store. The boot loader prompt at every boot is plain cryptsetup
    # — TPM unlock and other niceties are out of scope for v1.
    ask_yesno LUKS "encrypt root partition with LUKS (passphrase prompt at install + boot)?" "no"

    # Recovery shell: a known root password from day one means a
    # broken X / display manager / HM activation never leaves you
    # locked out — drop to a TTY, or `ssh root@host` from another
    # box on the LAN. Plain text; rotate on first login.
    echo
    echo "Recovery: root password (plain text; rotate on first boot)."
    echo "  Empty = no root login (use only if you have other recovery)."
    ask ROOT_PASSWORD "root initial password" "recovery"

    ask_yesno UNATTENDED "unattended host (auto-upgrade + nixos-clone + hm-auto-upgrade)?" "$ROLE_UNATT"

    echo
    echo "═══ Summary ═══"
    echo "  hostname     : $HOSTNAME"
    echo "  role         : $ROLE"
    echo "  disko layout : $DISKO_LAYOUT"
    echo "  disk         : $DISK"
    echo "  primary user : $PRIMARY_USER ($PRIMARY_FULLNAME, hm=$PRIMARY_HM)"
    echo "  extra users  : ${EXTRA_USERS:-(none)}"
    echo "  features     : $COMMON_FEATURES + $FEATURES"
    echo "  unattended   : $UNATTENDED"
    echo "  LUKS         : $LUKS"
    if [[ -n "$ROOT_PASSWORD" ]]; then
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
