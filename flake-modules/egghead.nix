# egghead — opinionated installer wizard for this flake.
#
# Two contributions:
#
#   1. packages.<system>.egghead — `nix run github:dc0d32/nixos#egghead`
#      runs the TypeScript+Ink TUI front-end (packages/egghead/) which
#      gathers wizard answers then execs the bash engine
#      (scripts/egghead.sh, also exposed as packages.<system>.egghead-sh
#      for slim/headless environments) with EGGHEAD_* env vars set.
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
# Phase 3 status: the TUI is the default `egghead` package; the bash
# script is still the single source of truth for what gets written to
# disk and is shipped as `egghead-sh` for environments where the Node
# closure is too heavy or stdin isn't a TTY.
#
# Retire when: the flake stops being a "private opinionated distro" and
# moves to hand-rolled host bridges only, OR the wizard graduates to a
# proper installer ISO + first-class TUI that supersedes this skeleton.
{ inputs, ... }:
{
  perSystem = { pkgs, system, ... }:
    let
      # Runtime PATH for the bash engine. Shared between egghead-sh
      # (when invoked directly) and the TUI wrapper (which prepends
      # this to PATH before exec'ing bash).
      bashRuntimeInputs = with pkgs; [
        bash
        coreutils
        util-linux
        git
        gnused
        gnugrep
        gawk
        # jq parses EGGHEAD_EXTRA_USERS_JSON (TUI hands users in as a
        # structured array); mkpasswd hashes plain passwords into
        # yescrypt-format `initialHashedPassword` strings safe to
        # commit into the host bridge.
        jq
        mkpasswd
        # nix is needed to invoke `nix run`-style helpers downstream;
        # nixos-install / nixos-generate-config come from the live
        # installer ISO, not from this package's closure (the package
        # is tiny on purpose so `nix run` from the installer is fast).
        nix
      ];

      egghead-sh = pkgs.writeShellApplication {
        name = "egghead-sh";
        runtimeInputs = bashRuntimeInputs;
        # SC2034 and SC2153: shellcheck can't see indirect variable
        # references (we look up role_<x>_<y> via `${!key}` in
        # role_lookup() and set wizard outputs via `printf -v VAR`).
        # SC2317: trap-set cleanup functions look unreachable to
        # shellcheck. SC2155: `local x=$(…)` is intentional throughout.
        excludeShellChecks = [ "SC2034" "SC2153" "SC2317" "SC2155" ];
        # Bake the source revision the wizard was built from into the
        # default EGGHEAD_FLAKE_REF. Without this, the wizard built
        # from a feature branch would still `git clone --branch main`,
        # producing a checkout whose host-setup.sh predates whatever
        # flags the wizard tries to hand off. `inputs.self.rev` is
        # populated when the flake comes from a github fetch (i.e. how
        # SL3 launches it via `nix run github:…`); `dirtyRev` covers
        # local-tree builds. Fall back to "main" for the extreme edge
        # case where neither is set.
        text =
          let
            # Only use a clean revision; dirty local-tree builds
            # produce "<sha>-dirty" which isn't a valid git ref. Local
            # dev hits this branch and keeps the historical "main"
            # default, which is fine because local dev typically uses
            # --no-clone / --workdir to point at the live tree.
            sourceRev = inputs.self.rev or "main";
          in
          builtins.replaceStrings
            [ "EGGHEAD_FLAKE_REF:=main" ]
            [ "EGGHEAD_FLAKE_REF:=${sourceRev}" ]
            (builtins.readFile ../scripts/egghead.sh);
      };

      # In-store path to the bash entry point. The TUI wrapper sets
      # EGGHEAD_BASH_SCRIPT to this; bash sees `/nix/store/.../bin/
      # egghead-sh` and execs into it under the wrapper's PATH.
      eggheadBashPath = "${egghead-sh}/bin/egghead-sh";

      egghead = pkgs.callPackage ../packages/egghead {
        bashScript = eggheadBashPath;
        runtimeInputs = bashRuntimeInputs;
      };
    in
    {
      packages.egghead = egghead;
      packages.egghead-sh = egghead-sh;
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
          # Self-heal: install-time `host-setup.sh do_clone_sources`
          # is supposed to drop the flake at ~/<primary>/nixos, but a
          # flaky live-ISO network or HM bootstrap race can leave it
          # missing. If so, clone it ourselves so the primary user
          # has a working checkout from first login. Best-effort: a
          # truly offline first boot leaves $clone absent and we
          # take the "not a git checkout; skipping" branch below.
          if [[ ! -d "$clone/.git" ]]; then
            echo "egghead-amend: $clone missing; attempting clone."
            mkdir -p "/home/${primary}"
            if git clone https://github.com/dc0d32/nixos "$clone"; then
              chown -R ${primary}:users "$clone"
            else
              echo "egghead-amend: clone failed (network down?); skipping."
            fi
          fi
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
