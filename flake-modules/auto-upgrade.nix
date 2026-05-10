# auto-upgrade — daily `nixos-rebuild switch` against this flake's
# `origin/main` on GitHub.
#
# Why: hosts deployed across the homelab and family laptops drift
# from the repo as fixes/features land. Without auto-upgrade, the
# only way they pick up a change is for someone to SSH in (or sit
# down at the laptop) and run `sudo nixos-rebuild switch --flake
# .#<host>`. That's tolerable for one machine; it doesn't scale to
# four.
#
# What this module enables (via the upstream `system.autoUpgrade`):
#   - A daily systemd timer (`nixos-upgrade.timer`) that fires at
#     04:40 local time with up to 30min of randomized jitter, so
#     multiple hosts don't hit GitHub at the same second. Persistent
#     timer: if the host was off at 04:40, the upgrade runs as soon
#     as it boots and catches up.
#   - The unit runs `nixos-rebuild switch --refresh --flake
#     github:dc0d32/nixos`. With no fragment, nixos-rebuild picks
#     `nixosConfigurations.<networking.hostName>` automatically, so
#     no per-host string-interpolation is needed inside this module.
#   - `--refresh` forces a re-fetch of the GitHub tarball so we
#     pick up new commits each run instead of using the cached copy.
#
# What this module does NOT do (intentionally):
#   - **No `flake.lock` bumping.** The lock that ships in the repo
#     is what every host uses, so all hosts upgrade in lockstep
#     against the same nixpkgs/niri/etc. revisions. Lock bumps are
#     a manual `nix flake update` on the dev box, tested locally,
#     committed, pushed. Auto-bumping the lock here would mean each
#     host independently fetches whatever upstream is current at its
#     timer-fire moment, which is exactly the "auto-deploy untested
#     code" failure mode auto-update gets a bad reputation for.
#     (The default for `system.autoUpgrade` with a remote flake URI
#     is already no-bump — we don't pass `--update-input nixpkgs`
#     anywhere — but documenting it here for reviewers.)
#   - **No reboots.** `allowReboot = false`. Kernel/initrd updates
#     activate but don't take effect until the user reboots manually.
#     This is the single biggest "you'll regret it" knob — a bad
#     initrd auto-installed and auto-rebooted on a remote host (e.g.
#     ah-1) is a remote brick. Manual reboot on a maintenance window
#     is the only safe answer until we have remote-unlock + a
#     confidence-building track record.
#
# Pattern A (importing IS enabling, per AGENTS.md): hosts that want
# auto-upgrade simply import this module from their bridge file:
#   imports = [ … config.flake.modules.nixos.auto-upgrade ];
# Hosts that don't, don't. There is no per-feature `enable` flag.
#
# pb-x1 (the dev box) deliberately does NOT import this — see
# the comment in flake-modules/hosts/pb-x1.nix for how to opt in
# later if you want it.
#
# To watch what the timer is doing on a host:
#   systemctl status nixos-upgrade.timer
#   systemctl status nixos-upgrade.service
#   journalctl -u nixos-upgrade.service -n 200
#
# To trigger an upgrade manually (same code path the timer uses):
#   sudo systemctl start nixos-upgrade.service
#
# Retire when: a different deployment driver replaces this (e.g.
# `deploy-rs` push-based deploys from CI, or nix-darwin-style
# `nixos-rebuild --target-host` from a build server), OR the lock-
# in-the-repo policy changes (e.g. switch to per-host channel
# tracking) and this module's no-bump assumption no longer holds.
{ ... }: {
  flake.modules.nixos.auto-upgrade = { ... }: {
    system.autoUpgrade = {
      enable = true;

      # Public flake URI. With no `#<host>` fragment, nixos-rebuild
      # selects `nixosConfigurations.<networking.hostName>`. Keeping
      # the URI host-agnostic means this module has no per-host
      # branching — every host just imports it.
      flake = "github:dc0d32/nixos";

      # Default is 04:40 local; setting explicitly for visibility.
      # Format: see systemd.time(7).
      dates = "04:40";

      # Spread the timer over a 30-minute window. With 4-5 hosts
      # firing in the same minute we'd briefly hit GitHub's API
      # limits and possibly tarball-cache cold-misses. Jitter avoids
      # both.
      randomizedDelaySec = "30min";

      # Persistent timer: if the host was off at 04:40, run the
      # upgrade on next boot. Catches laptops that suspend overnight
      # and homelab VMs that get powered down.
      persistent = true;

      # NEVER auto-reboot. See module header.
      allowReboot = false;
    };
  };
}
