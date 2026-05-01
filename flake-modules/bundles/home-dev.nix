# Home-manager bundle: dev.
#
# Base bundle plus development tooling that every dev-capable account
# needs (currently: my account on every host, plus wsl). Kid accounts
# do NOT consume this.
#
# = base ++ [ ai-cli, build-deps ]
#
# Adding a new dev tool that should be on every dev account: add it
# here, not in the per-host bridges.
#
# Retire when: home-base is retired (this bundle can't outlive its
#   parent), OR the distinction between dev and headless accounts
#   collapses (e.g. you stop running wsl/ah-1 entirely).
{ config, ... }:
{
  flake.lib.bundles.homeManager.dev =
    config.flake.lib.bundles.homeManager.base
    ++ (with config.flake.modules.homeManager; [
      ai-cli
      build-deps
    ]);
}
