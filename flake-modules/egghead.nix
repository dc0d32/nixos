# egghead — opinionated installer wizard for this flake.
#
# Two contributions:
#
#   1. packages.<system>.egghead — `nix run github:dc0d32/nixos#egghead`
#      runs scripts/egghead.sh under writeShellApplication, with the
#      required runtime tools (git, coreutils, util-linux, etc.) on PATH.
#      Used from the official NixOS installer ISO to bring up a new
#      host without hand-editing flake-modules/hosts/<name>.nix.
#
#   2. flake.modules.nixos.egghead-amend — a per-host oneshot systemd
#      service that, on first boot, regenerates hardware-configuration.nix
#      against the installed kernel and commits any differences in the
#      primary user's ~/nixos clone. Self-disables via a sentinel file.
#      Only hosts created by egghead import this contribution; existing
#      hand-rolled hosts (pb-x1, pb-t480, etc.) ignore it.
#
# Why two contributions in one file: they share design context (the
# wizard generates a commit that the amend service may need to refresh
# on real hardware), and the surface area is small enough that splitting
# would be premature.
#
# Phase 1 (this file): shell-stub. Phase 3 plan: rewrite the wizard UI
# layer in TypeScript + Ink, keep the systemd surface identical.
#
# Retire when: the flake stops being a "private opinionated distro" and
# moves to hand-rolled host bridges only, OR the wizard graduates to a
# proper installer ISO + first-class TUI that supersedes this skeleton.
{ inputs, ... }:
{
  perSystem = { pkgs, system, ... }:
    let
      egghead = pkgs.writeShellApplication {
        name = "egghead";
        runtimeInputs = with pkgs; [
          bash
          coreutils
          util-linux
          git
          gnused
          gnugrep
          gawk
          # nix is needed to invoke `nix run`-style helpers downstream;
          # nixos-install / nixos-generate-config come from the live
          # installer ISO, not from this package's closure (the package
          # is tiny on purpose so `nix run` from the installer is fast).
          nix
        ];
        # SC2034 and SC2153: shellcheck can't see indirect variable
        # references (we look up role_<x>_<y> via `${!key}` in
        # role_lookup() and set wizard outputs via `printf -v VAR`).
        # SC2317: trap-set cleanup functions look unreachable to
        # shellcheck. SC2155: `local x=$(…)` is intentional throughout.
        excludeShellChecks = [ "SC2034" "SC2153" "SC2317" "SC2155" ];
        text = builtins.readFile ../scripts/egghead.sh;
      };
    in
    {
      packages.egghead = egghead;
    };

  # First-boot hwconfig amend service. Opt-in per host: the generated
  # host bridge adds `config.flake.modules.nixos.egghead-amend` to its
  # imports list.
  flake.modules.nixos.egghead-amend =
    { config, pkgs, lib, ... }:
    let
      hostName = config.networking.hostName;
      primary = config.users.primary;
      # Sentinel path keeps the unit a one-shot for the lifetime of
      # the host. Deleting the sentinel manually re-arms it on the
      # next boot — handy if the operator hand-edits hwconfig and
      # wants the amend logic to take another pass.
      sentinel = "/var/lib/egghead/amended-${hostName}";
    in
    {
      systemd.services."egghead-amend" = {
        description = "egghead: first-boot hwconfig amend for ${hostName}";
        wantedBy = [ "multi-user.target" ];
        # Wait for the user's clone to exist (nixos-clone landed it
        # at /home/<primary>/nixos) before trying to amend in there.
        after = [
          "network-online.target"
          "nixos-clone-${primary}.service"
          "home-manager-bootstrap-${primary}.service"
        ];
        wants = [ "network-online.target" ];
        # Idempotency: skip once the sentinel exists.
        unitConfig.ConditionPathExists = "!${sentinel}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Runs as root: nixos-generate-config wants to probe
          # /sys/firmware, lsblk every device, etc., and writing into
          # /home/<primary>/nixos as root is fine — we chown after.
          User = "root";
          TimeoutStartSec = "5min";
          Environment = [
            "PATH=${lib.makeBinPath [
              pkgs.coreutils
              pkgs.util-linux
              pkgs.git
              pkgs.diffutils
              pkgs.nixos-install-tools
            ]}"
          ];
        };
        script = ''
          set -euo pipefail
          clone="/home/${primary}/nixos"
          if [[ ! -d "$clone/.git" ]]; then
            echo "egghead-amend: $clone is not a git checkout; skipping."
            mkdir -p "$(dirname "${sentinel}")"
            : > "${sentinel}"
            exit 0
          fi
          target="$clone/hosts/${hostName}/hardware-configuration.nix"
          if [[ ! -f "$target" ]]; then
            echo "egghead-amend: $target missing; nothing to amend."
            mkdir -p "$(dirname "${sentinel}")"
            : > "${sentinel}"
            exit 0
          fi
          fresh="$(mktemp)"
          trap 'rm -f "$fresh"' EXIT
          # --no-filesystems matches what egghead and host-setup.sh
          # emit: disko owns fileSystems.* and swapDevices.
          nixos-generate-config --no-filesystems --show-hardware-config > "$fresh"
          if diff -q "$target" "$fresh" >/dev/null 2>&1; then
            echo "egghead-amend: hwconfig unchanged; nothing to commit."
          else
            echo "egghead-amend: hwconfig differs; refreshing + committing."
            cp -f "$fresh" "$target"
            chown ${primary}:users "$target"
            (
              cd "$clone"
              # Use the primary user's git identity if any; fall back
              # to a throwaway so the commit succeeds either way.
              if ! sudo -u ${primary} git config user.email >/dev/null 2>&1; then
                sudo -u ${primary} git config user.email "egghead-amend@local"
                sudo -u ${primary} git config user.name  "egghead-amend"
              fi
              sudo -u ${primary} git add "hosts/${hostName}/hardware-configuration.nix"
              sudo -u ${primary} git commit -m "egghead-amend: refresh hwconfig from first-boot kernel on ${hostName}"
            )
          fi
          mkdir -p "$(dirname "${sentinel}")"
          : > "${sentinel}"
        '';
      };
    };
}
