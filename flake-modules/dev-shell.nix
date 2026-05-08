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
#
# To activate the hooks, enter the devShell once (`nix develop` or, if you use
# direnv, `direnv allow`). The shellHook installs `.git/hooks/pre-commit`
# pointing at the wrapper produced by git-hooks.nix. After that, every commit
# runs the hooks. To bypass in an emergency: `git commit --no-verify` (but
# AGENTS.md forbids skipping hooks unless explicitly requested).
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
