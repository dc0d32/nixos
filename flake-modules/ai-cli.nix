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
# These tools authenticate via gh (`gh auth login`) or read keys from the
# user's shell environment / app keystores. There is no secrets framework
# in this repo today (see AGENTS.md); export keys from ~/.zshenv or a
# similar untracked dotfile until a secrets module is wired.
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
