# home-manager-bootstrap — auto-runs `home-manager switch` once per
# user on first boot of a freshly-installed system.
#
# Why: AGENTS.md keeps home-manager standalone (no NixOS HM module).
# That means `nixos-install` activates only the system closure; each
# user's HM profile must be activated separately. Without this module
# every fresh host requires manual per-user `nix run home-manager …` /
# `home-manager switch …` invocations, and on first login users land
# in a default desktop (e.g. ly default niri config, no quickshell, no
# zsh dotfiles) until somebody remembers to bootstrap them.
#
# How: for every standalone home-manager configuration named
# `<user>@<hostname>` matching this host's hostname, contribute a
# oneshot systemd service `home-manager-bootstrap-<user>.service`
# that runs the activation package's `activate` script as that user.
# The service is gated by
#   ConditionPathExists=!/home/<user>/.local/state/nix/profiles/home-manager
# so it only runs once per user (HM creates that profile symlink as
# the very last step of activation). Subsequent rebuilds and reboots
# are no-ops; users keep using the canonical `home-manager switch`
# CLI for routine updates.
#
# Network gating: `Wants=network-online.target` +
# `After=network-online.target` so the unit waits for actual
# connectivity (provided by NetworkManager-wait-online.service or
# systemd-networkd-wait-online.service, depending on the host) before
# running. Some HM activation steps (e.g. fetching things via gh,
# nix-index updates if enabled) need network; without this gate the
# unit would race the network stack on first boot and fail
# permanently because of the `ConditionPathExists` guard. If
# wait-online still times out (e.g. WiFi never authenticated on a
# laptop where no human logged in to enter credentials), the unit
# fails this boot and re-tries on the next boot — the profile
# symlink doesn't exist yet, so the condition still passes.
#
# On hosts without any wait-online provider (e.g. WSL), the
# network-online.target is reached immediately and the dependency is
# effectively a no-op.
#
# Naming convention required: the HM configuration MUST be named
# `<unix-user>@<hostname>`. Hosts that follow this convention (every
# host bridge in this repo does) get bootstrap for free by importing
# this module; no per-host wiring needed.
#
# Pattern A: hosts opt in by importing. Headless / single-user hosts
# (wsl, ah-1) where running `home-manager switch` once manually is
# fine can skip importing — but importing is harmless there too,
# since the service is one-shot and self-disabling.
#
# Architecture note: this module reads `config.flake.homeConfigurations`
# from the outer flake-parts config to obtain each HM config's
# `activationPackage` store path. That is a runtime store-path
# reference, NOT importing home-manager as a NixOS module — the
# AGENTS.md rule (HM stays standalone) is preserved. The system
# closure gains a runtime dependency on each per-user activation
# package, which means rebuilding the system also pulls the latest
# HM closure into the store (a feature, not a bug — keeps GC from
# pruning the bootstrap target before first boot).
#
# Retire when: every host either (a) has been bootstrapped already
# and we're confident no fresh installs will happen, OR (b) we adopt
# a different mechanism (e.g. autostart wrapper in the user session).
flakeArgs@{ config, lib, ... }:
let
  # Capture outer (flake-parts) config.flake.homeConfigurations once,
  # so the inner NixOS-class module function (which receives a
  # different `config` — the NixOS one) can still see it via this
  # let-binding. Module evaluation is lazy enough that by the time
  # the inner function runs, the outer attrset is fully resolved.
  outerHm = config.flake.homeConfigurations;
in
{
  config.flake.modules.nixos.home-manager-bootstrap =
    { config, pkgs, lib, ... }:
    let
      hostName = config.networking.hostName;
      forThisHost = lib.filterAttrs
        (cfgName: _: lib.hasSuffix "@${hostName}" cfgName)
        outerHm;
    in
    {
      systemd.services = lib.mapAttrs'
        (cfgName: hm:
          let
            user = lib.elemAt (lib.splitString "@" cfgName) 0;
            activate = "${hm.activationPackage}/activate";
          in
          lib.nameValuePair "home-manager-bootstrap-${user}" {
            description = "Bootstrap home-manager profile for ${user}";
            wantedBy = [ "multi-user.target" ];
            # Wait for actual connectivity before activating: some HM
            # modules' activation scripts hit the network. On hosts
            # without any wait-online provider (e.g. WSL) this is a
            # no-op since network-online.target is reached
            # immediately.
            wants = [ "network-online.target" ];
            after = [
              "network-online.target"
              "systemd-user-sessions.service"
            ];
            # Idempotency guard: HM creates this profile symlink as
            # the final step of `activate`. If it already exists, the
            # service is skipped on subsequent boots.
            unitConfig.ConditionPathExists =
              "!/home/${user}/.local/state/nix/profiles/home-manager";
            serviceConfig = {
              Type = "oneshot";
              User = user;
              Group = "users";
              RemainAfterExit = true;
              # HOME and XDG_* are required by the HM activation
              # script. PATH needs nix + standard utilities.
              Environment = [
                "HOME=/home/${user}"
                "XDG_CONFIG_HOME=/home/${user}/.config"
                "XDG_DATA_HOME=/home/${user}/.local/share"
                "XDG_STATE_HOME=/home/${user}/.local/state"
                "XDG_CACHE_HOME=/home/${user}/.cache"
                "PATH=${lib.makeBinPath [
                  pkgs.nix
                  pkgs.coreutils
                  pkgs.gnused
                  pkgs.gnugrep
                  pkgs.findutils
                ]}"
              ];
              ExecStart = activate;
              # Activation can take 30-60s on a fresh system; bump
              # the default 90s timeout to 10min just in case nix
              # has to fetch anything (substituters should have
              # served everything during nixos-install already).
              TimeoutStartSec = "10min";
            };
          })
        forThisHost;
    };
}
