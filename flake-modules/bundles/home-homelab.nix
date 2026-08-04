# Home-manager bundle: homelab.
#
# The terminal experience for a homelab node's operator account (`p`). It's
# a *tasteful subset* of the desktop experience — the full base shell
# customization (zsh.nix: starship/eza/atuin/fzf/zoxide/bat/ripgrep/fd/…)
# plus the AI CLI tools carried over from the desktop, plus homelab-specific
# extras (docker/ZFS TUIs + aliases). NO GUI (niri/alacritty/vscode/browsers)
# and no build-deps (servers run compose stacks, they don't compile).
#
# = base ++ [ ai-cli, homelab-terminal ]
#
# ai-cli is the one heavyweight here; drop it from this list if a given
# homelab host should stay lean.
#
# Consumed by the homelab nodes (via `pub.lib.bundles.homeManager.homelab`
# in the homelab/ submodule flake) as
# `p@<host>`.
#
# Retire when: home-base is retired, or the homelab collapses into another
#   account class.
{ config, ... }:
{
  flake.lib.bundles.homeManager.homelab =
    config.flake.lib.bundles.homeManager.base
    ++ (with config.flake.modules.homeManager; [
      ai-cli
      homelab-terminal
    ]);
}
