{ pkgs, ... }:
# AI assistant CLIs.
#
# These are user-scoped tools (they read user config from $XDG_CONFIG_HOME and
# auth tokens from the user's keyring), so they belong in home-manager rather
# than environment.systemPackages.
#
# - github-copilot-cli: `ghcs`/`ghce` shell suggestions, requires
#   `gh auth login` (handled by tools/gh.nix) and `gh extension install
#   github/gh-copilot` on first use.
# - opencode: this very tool. Config lives at ~/.config/opencode/.
{
  home.packages = with pkgs; [
    github-copilot-cli
    opencode
  ];
}
