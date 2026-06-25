# NixOS bundle: auto-deploy.
#
# The "pull from origin/main on a daily timer" automation trio. Hosts
# that are deployed-and-left (the family laptops/desktops and the
# homelab VMs) import all three together so they stay in lockstep with
# the repo without anyone SSHing in. Extracted on 2026-06-25 because
# m-pc, pb-t480, ah-1 and wsl each listed the same three modules.
#
# The dev box (pb-x1) deliberately does NOT import this — a 04:40
# nixos-rebuild timer racing in-progress edits is more annoying than
# useful there. See flake-modules/auto-upgrade.nix.
#
# Members:
#   auto-upgrade   daily `nixos-rebuild switch --refresh --flake
#                  github:dc0d32/nixos` (no reboot)
#   nixos-clone    per-user oneshot that clones the repo into ~/nixos
#   hm-auto-upgrade daily `home-manager switch` from github: for every
#                  HM user on the host
#
# NOTE: home-manager-bootstrap is intentionally NOT in this bundle — it
# is part of the workstation core (pb-x1 wants it without the rest of
# the auto-deploy trio), and the headless hosts (ah-1, wsl) import it
# explicitly alongside this bundle.
#
# Retire when: a different deployment driver replaces this (e.g.
#   deploy-rs push-based deploys), OR the repo's lock-in-the-repo
#   auto-upgrade policy changes.
{ config, ... }:
{
  flake.lib.bundles.nixos.auto-deploy = with config.flake.modules.nixos; [
    auto-upgrade
    nixos-clone
    hm-auto-upgrade
  ];
}
