# AI assistant CLIs.
#
# These are user-scoped tools (they read user config from $XDG_CONFIG_HOME and
# auth tokens from the user's keyring), so they belong in home-manager rather
# than environment.systemPackages.
#
# - github-copilot-cli: `ghcs`/`ghce` shell suggestions, requires
#   `gh auth login` (handled by ./gh.nix) and `gh extension install
#   github/gh-copilot` on first use.
# - opencode: this very tool. Config lives at ~/.config/opencode/.
#
# uv-installed AI tools (graphrag, graphifyy): neither is packaged in nixpkgs
# (graphifyy is too new; nixpkgs' graphrag is built against an unsupported
# python), so they come from PyPI via `uv tool install` -- the same mechanism
# the native-Windows toolkit uses (flake-modules/windows/windows.nix). The
# canonical list lives in `flake.lib.aiUvTools` so Linux and Windows install
# the same set from one definition.
#   - graphrag: Microsoft GraphRAG (`graphrag` CLI).
#   - graphifyy: the `graphify` AI-agent "memory layer" (its own README
#     recommends `uv tool install graphifyy`).
# The activation entry below mirrors the Windows setup.ps1 uv step: it
# installs only the MISSING tools (idempotent, fast on later switches) and is
# best-effort -- a failed/offline install warns but never aborts the switch.
# There is no auto-upgrade (same as Windows); run `uv tool upgrade --all` by
# hand. It runs only at real `home-manager switch` activation, never during
# `nix build` / `nix flake check`, so CI has no network dependency.
#
# uv itself comes from flake-modules/zsh.nix (Linux) / winget (Windows); the
# script calls it by its absolute store path so it works even where the zsh
# module isn't imported. nix-ld (flake-modules/nix-ld.nix) lets uv's managed
# Python run on NixOS.
#
# API keys (OPENAI_API_KEY, ANTHROPIC_API_KEY, etc) are NOT installed here.
# These tools authenticate via gh (`gh auth login`) or read keys from the
# user's shell environment / app keystores. There is no secrets framework
# in this repo today (see AGENTS.md); export keys from ~/.zshenv or a
# similar untracked dotfile until a secrets module is wired.
#
# Retire when: none of github-copilot-cli / opencode / the uv AI tools are
#   part of the daily workflow, or they are replaced by a different AI CLI
#   surface (e.g. a single editor-integrated assistant).
let
  # Single source of truth, also consumed by flake-modules/windows/windows.nix.
  # AI CLI tools with no nixpkgs package -> installed via `uv tool install`.
  aiUvTools = [
    "graphrag" # Microsoft GraphRAG -- `graphrag` CLI
    "graphifyy" # the `graphify` AI-agent memory layer
  ];
in
{
  flake.lib.aiUvTools = aiUvTools;

  flake.modules.homeManager.ai-cli = { pkgs, lib, config, ... }:
    let
      # uv installs tool executables into its default user bin dir; surface
      # it on PATH (zsh lacks it -- fish.nix already adds it for fish).
      localBin = "${config.home.homeDirectory}/.local/bin";
    in
    {
      home.packages = with pkgs; [
        github-copilot-cli
        opencode
      ];

      home.sessionPath = [ localBin ];

      home.activation.aiUvTools = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        uv=${pkgs.uv}/bin/uv
        installed="$("$uv" tool list 2>/dev/null || true)"
        for tool in ${lib.escapeShellArgs aiUvTools}; do
          if printf '%s\n' "$installed" | ${pkgs.gnugrep}/bin/grep -q "^$tool "; then
            verboseEcho "ai-cli: uv tool '$tool' already installed"
          else
            verboseEcho "ai-cli: installing uv tool '$tool'"
            $DRY_RUN_CMD ${pkgs.coreutils}/bin/timeout 900 "$uv" tool install "$tool" \
              || warnEcho "ai-cli: 'uv tool install $tool' failed (offline?); rerun 'uv tool install $tool' later."
          fi
        done
      '';
    };
}
