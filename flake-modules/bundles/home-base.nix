# Home-manager bundle: base.
#
# The minimum HM module set that every account in this flake imports
# regardless of role. Headless hosts (wsl, ah-1) consume this directly;
# desktop bundles compose on top.
#
# Members:
#   - btop          system monitor
#   - direnv        per-project env
#   - gh            GitHub CLI
#   - git           version control + identity
#   - neovim        editor
#   - nix-settings  user-profile GC policy (mirrors NixOS-side
#                   nix-settings; see flake-modules/nix-settings-hm.nix)
#   - tmux          terminal multiplexer
#   - zsh           login shell
#
# Adding a new universally-needed HM module: add it here and it
# propagates to every account in the flake.
#
# Published under flake.lib.bundles.homeManager.base (lists are
# placed under flake.lib because flake-parts only recognizes a fixed
# set of top-level flake.* attrs; lib is the documented escape hatch
# for arbitrary user-defined values).
#
# Retire when: the flake collapses to a single account (no need for
#   shared bundles), OR home-manager grows a first-class "profile"
#   abstraction that supersedes this one.
{ config, ... }:
{
  flake.lib.bundles.homeManager.base = with config.flake.modules.homeManager; [
    btop
    direnv
    gh
    git
    neovim
    nix-settings
    tmux
    zsh
  ];
}
