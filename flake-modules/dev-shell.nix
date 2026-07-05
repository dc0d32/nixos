# Default devShell for hacking on this flake itself.
#
# Provides nix tooling, git, pre-commit hooks (via cachix/git-hooks.nix), and
# rebuild ergonomics (nh + nvd + nom).
#
# Tooling exposed in $PATH:
#   - nh                  : friendly wrapper around nixos-rebuild / home-manager
#                           switch / nix-collect-garbage. Shows a closure diff
#                           via nvd by default. NH_FLAKE is set in shellHook
#                           via `git rev-parse --show-toplevel` so `nh os
#                           switch` and `nh home switch <user>@<host>` work
#                           without a positional flakeref from anywhere inside
#                           the repo.
#   - nvd                 : closure-diff tool. Useful standalone for diffing two
#                           store paths or two generations.
#   - nix-output-monitor  : structured rebuild progress; pipe nix builds through
#                           it as `nix build … |& nom` for human-readable output
#                           (nh already calls nom internally for switches).
#   - nixpkgs-fmt         : invoked by `nix fmt` and the pre-commit hook.
#   - gitleaks            : invoked by the pre-commit hook (see below).
#   - nix, git            : substrate.
#
# Hooks installed:
#   - gitleaks            : scans staged content for secrets (API keys, age
#                           private keys, AWS creds, etc). REPO IS PUBLIC
#                           — a leaked token gets scraped within minutes
#                           of pushing, so this is the last line of
#                           defense against an accidental paste of an API
#                           key, password, or other credential into a
#                           tracked file. Stays useful even though the
#                           repo currently has no secrets framework
#                           wired (see AGENTS.md).
#   - nixpkgs-fmt         : keeps `.nix` formatting consistent with `nix fmt`.
#   - check-bash-shebang  : rejects scripts whose shebang hardcodes a path
#                           to bash (`#!/bin/bash`, `#!/usr/bin/bash`,
#                           etc.). Default NixOS doesn't ship those paths
#                           — only `/bin/sh` and `/usr/bin/env` are
#                           guaranteed. WSL ships `/bin/bash` for compat,
#                           which lets the bug hide if the script is
#                           authored on WSL and shipped to bare-metal
#                           NixOS. Use `#!/usr/bin/env bash` instead.
#                           See AGENTS.md > "Shell script shebangs".
#   - check-no-private-topology : rejects staged changes that introduce
#                           real homelab topology (private domain, RFC1918
#                           VLAN subnets, disk serials, the real hostnames)
#                           into this PUBLIC repo. That data lives only in
#                           the separate private dc0d32/homelab flake; the
#                           reusable modules here use documentation-range
#                           placeholders. Diff-based, like gitleaks.
#   - smoke-build-hosts   : pre-PUSH hook (not pre-commit). Runs
#                           `nix flake check --impure` with
#                           NIXOS_ALLOW_PLACEHOLDER=1 so every
#                           non-placeholder, native-arch NixOS and
#                           home-manager configuration gets evaluated
#                           AND built before the push completes.
#                           Catches both eval breakage and build
#                           failures before they reach origin/main —
#                           critical now that secondary hosts
#                           (pb-t480, ah-1, m-pc, wsl) auto-upgrade
#                           from origin/main daily via flake-modules/
#                           auto-upgrade.nix; pushing a broken main
#                           bricks their next 24h of upgrades.
#                           Skip with `git push --no-verify` only if
#                           there's an explicit reason (AGENTS.md).
#
# To activate the hooks, enter the devShell once (`nix develop` or, if you use
# direnv, `direnv allow`). The shellHook installs `.git/hooks/pre-commit`
# AND `.git/hooks/pre-push` (git-hooks.nix automatically adds the pre-push
# git hook because the smoke-build-hosts hook declares `stages = [ "pre-push" ]`).
# After that, every commit runs the pre-commit hooks and every push runs
# the smoke build. To bypass in an emergency: `git commit --no-verify` or
# `git push --no-verify` (but AGENTS.md forbids skipping hooks unless
# explicitly requested).
#
# Editor / language tools are not added here — they belong in the user's
# home-manager config.
#
# Retire when: gitleaks/pre-commit is no longer wanted (e.g. repo goes private
# AND all secrets are managed via a hardware token), or this is replaced by a
# native git server-side hook. The nh/nvd/nom additions can be dropped
# independently if a different rebuild driver replaces them.
{ inputs, ... }: {
  perSystem = { pkgs, system, ... }:
    let
      # Bash-shebang lint: reject scripts that hardcode a path to bash
      # (`#!/bin/bash`, `#!/usr/bin/bash`, `#!/usr/local/bin/bash`).
      # NixOS does not ship `/bin/bash` on a default install — only
      # `/bin/sh` and `/usr/bin/env` are guaranteed — so any
      # hardcoded-bash shebang fails with `bad interpreter: No such
      # file or directory` on a fresh bare-metal NixOS system. The
      # WSL fork happens to populate `/bin/bash` for compat, which
      # makes this footgun easy to miss when authoring a script on
      # WSL and shipping it to pb-x1/pb-t480.
      #
      # Allowed shebangs: `#!/usr/bin/env bash`, `#!/bin/sh`,
      # `#!/usr/bin/env python3`, etc. — anything not matching the
      # hardcoded-bash regex passes silently.
      #
      # The hook is implemented as a `pkgs.writeShellApplication` so
      # its own shebang is a Nix-store path (i.e. it doesn't itself
      # depend on `/bin/bash` — that would be self-defeating).
      check-bash-shebang = pkgs.writeShellApplication {
        name = "check-bash-shebang";
        runtimeInputs = with pkgs; [ coreutils gnugrep ];
        text = ''
          # Pre-commit passes the list of staged filenames as args.
          # For each file: peek at the first line, and if it matches
          # a hardcoded bash interpreter path, record an offender.
          status=0
          for f in "$@"; do
            # Skip directories, symlinks-to-nowhere, and binaries.
            [[ -f "$f" && -r "$f" ]] || continue
            # Read just the first line; bail fast on non-script files.
            first="$(head -n1 -- "$f" 2>/dev/null || true)"
            case "$first" in
              "#!"/bin/bash*|"#!"/usr/bin/bash*|"#!"/usr/local/bin/bash*)
                echo "✘ $f: $first" >&2
                status=1
                ;;
            esac
          done
          if [[ $status -ne 0 ]]; then
            cat >&2 <<'EOF'

          Hardcoded bash shebang found. NixOS does not ship /bin/bash on a
          default install (only /bin/sh and /usr/bin/env). Use the portable
          form instead:

              #!/usr/bin/env bash

          See AGENTS.md > "Shell script shebangs".
          EOF
          fi
          exit $status
        '';
      };

      # check-no-private-topology: block homelab topology (real hostnames,
      # RFC1918 subnets, disk serials, the private domain) from ever being
      # committed to this PUBLIC repo. The real topology lives ONLY in the
      # private `dc0d32/homelab` flake (a separate flake that consumes this
      # one as an input); the reusable modules here use documentation-range
      # examples (192.0.2.x, placeholder serials) so this repo carries no
      # leak surface. See homelab/sessions/ for the architecture.
      #
      # Diff-based (scans staged ADDED lines only, like gitleaks) so
      # already-committed personal references (e.g. a bitwarden URL in a
      # host's chrome policy) don't block unrelated commits — only NEW
      # introductions are rejected. The hook excludes its OWN definition
      # file (this dev-shell.nix necessarily spells the patterns out).
      #
      # Bypass a false positive with `git commit --no-verify` (AGENTS.md:
      # only with an explicit, documented reason).
      check-no-private-topology = pkgs.writeShellApplication {
        name = "check-no-private-topology";
        runtimeInputs = with pkgs; [ git gnugrep coreutils ];
        text = ''
          # Staged added lines, excluding this hook's own source (which
          # necessarily contains the very patterns it searches for).
          added="$(git diff --cached --unified=0 --no-color -- . \
            ':(exclude)flake-modules/dev-shell.nix' \
            | grep -E '^\+' | grep -Ev '^\+\+\+' || true)"

          # Regexes for real homelab topology that must stay private.
          patterns=(
            'bitset\.cc'                 # private domain
            '192\.168\.'                 # real VLAN subnets (RFC1918)
            'MZ7WD480HCGM|SSDSC2KF256'   # real storage-node boot-SSD serials
            'MZVKW1T0HMLH|MTFDDAK1T0MBF' # real edge-node disk serials
            '\b(andromeda|ursa)\b'       # real hostnames
          )

          status=0
          for p in "''${patterns[@]}"; do
            hits="$(printf '%s\n' "$added" | grep -inE "$p" || true)"
            if [[ -n "$hits" ]]; then
              echo "✘ private topology /$p/ in staged changes:" >&2
              printf '%s\n' "$hits" >&2
              status=1
            fi
          done

          if [[ $status -ne 0 ]]; then
            cat >&2 <<'EOF'

          Refusing to commit private homelab topology to the PUBLIC repo.
          Real hostnames, RFC1918 subnets, disk serials and the private
          domain belong ONLY in the private dc0d32/homelab flake. Use a
          documentation-range placeholder here (192.0.2.x, a generic
          "storage-node"/"edge-node", ata-<MODEL>_<SERIAL>) instead.

          If this is a genuine false positive: git commit --no-verify
          (AGENTS.md: only with an explicit, documented reason).
          EOF
          fi
          exit $status
        '';
      };

      # Pre-push smoke build: evaluate-and-build every non-placeholder,
      # native-arch NixOS and home-manager configuration before letting
      # the push complete. Catches eval breakage AND build failures
      # before they hit GitHub — which matters because the secondary
      # hosts (pb-t480, ah-1, m-pc, wsl) auto-upgrade from origin/main
      # via flake-modules/auto-upgrade.nix. A broken main branch means
      # those hosts spend the next 24h trying and failing to upgrade.
      #
      # Implementation: `nix flake check` builds every entry in
      # `flake.checks.<currentSystem>` (assembled by
      # flake-modules/nixos.nix and the home-manager dispatcher).
      # That auto-list already filters out placeholders and
      # non-native arches, so we don't redo that filtering here.
      # `--impure` + `NIXOS_ALLOW_PLACEHOLDER=1` is required because
      # `nix flake check` walks every entry in `nixosConfigurations`
      # regardless of which subset ends up in checks (a built-in CLI
      # behavior we can't suppress) and the placeholder hosts'
      # toplevel evaluation would otherwise abort. See AGENTS.md >
      # "Placeholder hosts".
      #
      # `--all-systems` is intentionally NOT passed: we only build
      # for the local arch. Cross-arch hosts (e.g. wsl-arm) get
      # validated when their owner runs the hook from a matching
      # machine. With one of each arch in the loop (x86_64-linux on
      # pb-x1/pb-t480/ah-1/m-pc/wsl, aarch64-linux on wsl-arm) the
      # union of pre-push checks across users covers everything.
      #
      # Runtime: warm cache ~5-15s for the eval pass, plus whatever
      # rebuild is needed. Cold first run after a nixpkgs bump can
      # take many minutes — skip the hook with `git push --no-verify`
      # if you genuinely need to push fast (AGENTS.md allows it for
      # "explicit user request"; document why in the commit message).
      smoke-build-hosts = pkgs.writeShellApplication {
        name = "smoke-build-hosts";
        runtimeInputs = with pkgs; [ nix coreutils ];
        text = ''
          echo "→ smoke-build: nix flake check (all native-arch hosts)" >&2
          # NIXOS_ALLOW_PLACEHOLDER=1 lets nixosConfigurations walk
          # past the placeholder-host assertions that protect against
          # accidental `nixos-rebuild switch` on an unbootable config.
          # --impure is then required by `nix flake check` to honor
          # any environment-variable reads in the eval. See
          # flake-modules/nixos.nix and AGENTS.md > "Placeholder
          # hosts".
          NIXOS_ALLOW_PLACEHOLDER=1 exec nix flake check --impure --print-build-logs
        '';
      };

      pre-commit-check = inputs.git-hooks.lib.${system}.run {
        src = ../.;
        hooks = {
          # Custom gitleaks hook — git-hooks.nix doesn't ship a built-in
          # one in the version we pin, so we define it as a generic
          # `system`-language hook. `gitleaks protect --staged` scans the
          # currently-staged diff and exits non-zero on a finding.
          gitleaks = {
            enable = true;
            name = "gitleaks (secret scan)";
            entry = "${pkgs.gitleaks}/bin/gitleaks protect --staged --redact --verbose";
            language = "system";
            # We want to scan the staged diff as a whole, not be invoked
            # once per file — pre-commit's default behavior of passing
            # filenames as args would make gitleaks scan those files'
            # contents on disk (which may differ from what's staged) and
            # is the wrong mode for this hook.
            pass_filenames = false;
          };
          nixpkgs-fmt.enable = true;

          # See `check-bash-shebang` above. Receives staged filenames
          # as args (pass_filenames = true, the default). The hook
          # filters internally: anything whose first line isn't a
          # `#!/{bin,usr/bin,usr/local/bin}/bash` shebang is a silent
          # no-op, so adding new .nix / .md / .qml / etc. files
          # doesn't trigger it.
          check-bash-shebang = {
            enable = true;
            name = "no hardcoded /bin/bash shebangs";
            entry = "${check-bash-shebang}/bin/check-bash-shebang";
            language = "system";
            pass_filenames = true;
          };

          # See `check-no-private-topology` above. Runs once (not per
          # file) and inspects the staged diff for real homelab topology
          # that must never reach this public repo.
          check-no-private-topology = {
            enable = true;
            name = "no private homelab topology";
            entry = "${check-no-private-topology}/bin/check-no-private-topology";
            language = "system";
            pass_filenames = false;
          };

          # See `smoke-build-hosts` above. `stages = [ "pre-push" ]`
          # makes git-hooks.nix install a `pre-push` git hook in
          # addition to the `pre-commit` one, so this fires only at
          # `git push` time — too slow to run on every commit, but
          # the right gate before code reaches origin/main where
          # secondary hosts auto-upgrade from.
          smoke-build-hosts = {
            enable = true;
            name = "smoke build all native-arch hosts";
            entry = "${smoke-build-hosts}/bin/smoke-build-hosts";
            language = "system";
            stages = [ "pre-push" ];
            # The script doesn't read filenames; it always does a
            # full flake-check.
            pass_filenames = false;
          };
        };
      };
    in
    {
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          nix
          nixpkgs-fmt
          git
          gitleaks
          # Rebuild ergonomics. nh shells out to nixos-rebuild / home-manager
          # and pipes their output through nom; nvd diffs the resulting
          # closure against the previous generation. Available standalone too.
          nh
          nvd
          nix-output-monitor
        ];

        # Run the pre-commit installer first, then resolve NH_FLAKE at shell-
        # init time. NH_FLAKE has to be the workspace root, NOT the store
        # path of this module — `toString ../..` would resolve relative to
        # the store copy of dev-shell.nix and give /nix/store. Resolving at
        # runtime via `git rev-parse` keeps it correct regardless of which
        # subdirectory the user opened the dev-shell from. Falls back to
        # PWD if not in a git checkout (rare; covers the case of running
        # the dev-shell over a tarball/zip of the flake).
        shellHook = ''
          ${pre-commit-check.shellHook}
          export NH_FLAKE="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        '';
      };

      # Expose the check so `nix flake check` runs gitleaks too — catches
      # the case where someone bypassed the local hook with --no-verify
      # before pushing. CI (if/when added) can run `nix flake check` to
      # enforce server-side.
      checks.pre-commit = pre-commit-check;
    };
}
