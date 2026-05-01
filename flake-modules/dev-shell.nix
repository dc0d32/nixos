# Default devShell for hacking on this flake itself.
#
# Provides nix tooling, git, and pre-commit hooks (via cachix/git-hooks.nix).
#
# Hooks installed:
#   - gitleaks      : scans staged content for secrets (API keys, age private
#                     keys, AWS creds, etc). REPO IS PUBLIC — a leaked token
#                     gets scraped within minutes of pushing, so this is the
#                     last line of defense before sops-encrypted secrets land
#                     in `secrets/*.yaml`.
#   - nixpkgs-fmt   : keeps `.nix` formatting consistent with `nix fmt`.
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
# native git server-side hook.
{ inputs, ... }: {
  perSystem = { pkgs, system, ... }:
    let
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
        ];

        # `inherit (pre-commit-check) shellHook` would also work, but being
        # explicit makes the wiring visible.
        shellHook = pre-commit-check.shellHook;
      };

      # Expose the check so `nix flake check` runs gitleaks too — catches
      # the case where someone bypassed the local hook with --no-verify
      # before pushing. CI (if/when added) can run `nix flake check` to
      # enforce server-side.
      checks.pre-commit = pre-commit-check;
    };
}
