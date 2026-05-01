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
# API keys (OPENAI_API_KEY, ANTHROPIC_API_KEY, etc) are NOT installed here.
# Hosts that need them should:
#   1. Import config.flake.modules.homeManager.secrets (and set
#      secrets.{ageKeyFile,commonFile} per flake-modules/secrets.nix).
#   2. Declare the secrets in their host bridge:
#        sops.secrets.openai_api_key    = {};
#        sops.secrets.anthropic_api_key = {};
#   3. Source the decrypted files into the shell, e.g.:
#        programs.zsh.initContent = lib.mkAfter ''
#          [ -r ${config.sops.secrets.openai_api_key.path} ] && \
#            export OPENAI_API_KEY="$(cat ${config.sops.secrets.openai_api_key.path})"
#          [ -r ${config.sops.secrets.anthropic_api_key.path} ] && \
#            export ANTHROPIC_API_KEY="$(cat ${config.sops.secrets.anthropic_api_key.path})"
#        '';
# This pattern keeps secret values out of the Nix store; only the file path
# (a public path under /run/user/<uid>/secrets/) appears in zshrc.
#
# Retire when: neither github-copilot-cli nor opencode is part of the daily
#   workflow, or both are replaced by a different AI CLI surface (e.g. a
#   single editor-integrated assistant).
{
  flake.modules.homeManager.ai-cli = { pkgs, ... }: {
    home.packages = with pkgs; [
      github-copilot-cli
      opencode
    ];
  };
}
