# NixOS bundle: auto-deploy.
#
# The pull-from-`origin/main` automation, imported as a set by every
# host that should stay in lockstep with the repo without anyone SSHing
# in. Extracted on 2026-06-25 because m-pc, pb-t480 and wsl each
# listed the same modules; pb-x1 (the dev box) joined on 2026-08-04
# once the driver learned to prefer a quiet window and hold off on
# battery, which removed the "a 04:40 rebuild races my in-progress
# edits" objection.
#
# Members:
#   auto-update     the driver: hourly poll, quiet-window + staleness +
#                   wall-power + reachability gate, ordering, status
#                   CLIs. Declares the `autoUpdate.*` options the other
#                   two read.
#   auto-upgrade    `nixos-auto-upgrade.service` — `nixos-rebuild
#                   switch --refresh --flake github:dc0d32/nixos#<host>`
#                   (never reboots, never bumps the lock)
#   hm-auto-upgrade `hm-auto-upgrade.service` — `home-manager switch`
#                   for every HM user on the host, run after the system
#                   rebuild
#   nixos-clone     per-user oneshot that clones the repo into ~/nixos
#
# The three auto-update members are one unit of deployment on purpose:
# `auto-upgrade` and `hm-auto-upgrade` read options declared by
# `auto-update`, so importing either without the driver is an eval
# error. Splitting them would trade a clear eval error for a silent
# "your timer exists but nothing schedules it".
#
# NOTE: home-manager-bootstrap is intentionally NOT in this bundle — it
# is part of the workstation core, and the headless WSL hosts import it
# explicitly alongside this bundle.
#
# A host on a placeholder hardware-configuration.nix must NOT be given
# this bundle: `nixos-rebuild --flake github:…` evaluates purely, where
# `builtins.getEnv` returns "", so the placeholder assertion can never
# pass and every single run aborts. The retired ah-1 did exactly that for
# months behind a green CI. See AGENTS.md > "Placeholder hosts".
#
# Retire when: a different deployment driver replaces this (e.g.
#   deploy-rs push-based deploys), OR the repo's lock-in-the-repo
#   auto-upgrade policy changes.
{ config, ... }:
{
  flake.lib.bundles.nixos.auto-deploy = with config.flake.modules.nixos; [
    auto-update
    auto-upgrade
    nixos-clone
    hm-auto-upgrade
  ];
}
