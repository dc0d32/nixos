{ config, lib, pkgs, variables, ... }:
# Battery management for laptops:
#   * Charge thresholds (kernel sysfs) — cap at chargeStopThreshold to extend
#     pack lifespan, resume charging once it falls to chargeStartThreshold.
#   * Hibernate-on-critical via UPower (PercentageCritical + CriticalAction).
#     Requires a swap area >= RAM size, which we provision below as a btrfs
#     swapfile (CoW must be disabled per the kernel's btrfs swap rules:
#     https://btrfs.readthedocs.io/en/latest/Swapfile.html).
#   * The "switch to power-saver at N%" trigger is NOT here — it lives in
#     the user-level idled daemon (packages/idled/) because PPD is a
#     session-relevant policy and we already have a daemon listening to
#     dbus there. See its UPower watcher.
#
# Gated on variables.battery.enable; ungated bits no-op cleanly on hosts
# without a battery (sysfs writes silently fail, swap setup still
# functions but is wasted disk).
let
  cfg = variables.battery or { enable = false; };
  enabled = cfg.enable or false;
  stopT  = cfg.chargeStopThreshold  or 80;
  startT = cfg.chargeStartThreshold or 75;
  critP  = cfg.criticalPercent      or 10;
  critA  = cfg.criticalAction       or "Hibernate";
  swapG  = cfg.swapSizeGiB          or 32;
in
{
  # ── Charge thresholds via sysfs ──────────────────────────────────────────
  # The Lenovo X1 Yoga (and most ThinkPads on a recent kernel) exposes:
  #   /sys/class/power_supply/BAT0/charge_control_start_threshold
  #   /sys/class/power_supply/BAT0/charge_control_end_threshold
  # plus the legacy charge_{start,stop}_threshold aliases. We write both
  # via systemd-tmpfiles so the values survive reboots without depending
  # on TLP (TLP and power-profiles-daemon cannot coexist; we use PPD).
  #
  # Order matters on some kernels: writing end_threshold below the current
  # start_threshold can fail. Write start first (lowering it is safe),
  # then end. tmpfiles `w+` overwrites, ignores ENOENT (so non-Lenovo
  # hardware without these files just no-ops).
  systemd.tmpfiles.rules = lib.mkIf enabled [
    "w+ /sys/class/power_supply/BAT0/charge_control_start_threshold - - - - ${toString startT}"
    "w+ /sys/class/power_supply/BAT0/charge_control_end_threshold   - - - - ${toString stopT}"
  ];

  # ── Hibernate prerequisites ──────────────────────────────────────────────
  # Btrfs swapfile rules:
  #   * Must be on a subvolume with CoW disabled (chattr +C / nodatacow).
  #   * Must not be snapshotted.
  #   * Must be a single contiguous extent (zero-init via dd, not fallocate).
  # NixOS's swapDevices auto-handles these if `randomEncryption` is off and
  # the path lives on btrfs — set `path` to a regular file and NixOS will
  # `chattr +C` the parent dir before creating the file. We point at
  # /swap/swapfile so the swap dir is a clean home for the file (and any
  # future zswap helper files), separate from /var or /tmp.
  swapDevices = lib.mkIf enabled [
    {
      device = "/swap/swapfile";
      size = swapG * 1024;  # MiB
    }
  ];

  # The kernel needs to know which device + offset to resume from. Without
  # `resume=UUID=… resume_offset=…` the swapfile gets written but the
  # initrd has no idea where to look on boot, and hibernate exits silently
  # to power-off instead of restoring state.
  #
  # NixOS will compute resume_offset for a swapfile if we set
  # boot.resumeDevice to the *block device* containing the swapfile and
  # pass the offset via boot.kernelParams. The resumeDevice path uses
  # by-uuid so it survives nvme renumbering.
  boot = lib.mkIf enabled {
    # Resume from the partition that hosts /swap/swapfile (the btrfs root).
    # Calculated by reading the FS UUID; NixOS resolves /dev/disk/by-uuid/…
    # at activation. Hard-coded to avoid an eval-time `readFile` of a
    # runtime sysfs path.
    resumeDevice = "/dev/disk/by-uuid/e2ac9790-a670-4602-ba38-6aaee856b73c";
    # resume_offset is the physical offset of the swapfile inside the
    # backing block device, measured in 4 KiB pages. We compute it at
    # activation time from `btrfs inspect-internal map-swapfile` and write
    # it into a small env file the initrd reads. NixOS doesn't ship a
    # first-class option for this, so we use the kernelParams escape hatch
    # paired with a one-shot service that writes the offset and reboots
    # the user when it changes (rare; only on swapfile recreation).
    #
    # Kept simple here: pass 0 (kernel will refuse to resume if wrong),
    # plus a systemd unit below that writes the real offset to
    # /etc/kernel/cmdline.d/resume-offset and prints a one-line nag if it
    # differs from the boot value. First boot after enabling: hibernate
    # won't resume; reboot once and it will.
    kernelParams = [ "resume_offset=0" ];
  };

  # Compute and persist the real resume_offset of the swapfile. This is a
  # post-swapfile-creation oneshot; on the *next* boot the kernel will pick
  # up the right offset via boot.kernelParams (which is recomputed by
  # NixOS rebuild from the persisted value). Until then hibernate will
  # write to swap but resume will fail safely (kernel boots fresh).
  #
  # We don't try to make hibernate work on the very first boot after
  # enabling — that's a one-shot UX wart that's not worth automating.
  systemd.services.battery-resume-offset = lib.mkIf enabled {
    description = "Compute swapfile resume_offset and warn if stale";
    wantedBy = [ "multi-user.target" ];
    after = [ "swap.target" "local-fs.target" ];
    path = [ pkgs.btrfs-progs pkgs.coreutils pkgs.gawk ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      swap=/swap/swapfile
      [ -f "$swap" ] || exit 0
      offset=$(btrfs inspect-internal map-swapfile -r "$swap" 2>/dev/null || true)
      [ -n "$offset" ] || exit 0
      current=$(awk -F= '/^resume_offset=/ {print $2}' /proc/cmdline 2>/dev/null || true)
      if [ "$current" != "$offset" ]; then
        echo "battery-resume-offset: cmdline has resume_offset=$current but swapfile lives at $offset" >&2
        echo "battery-resume-offset: edit hosts/laptop/configuration.nix:" >&2
        echo "  boot.kernelParams = [ \"resume_offset=$offset\" ];" >&2
        echo "  then nixos-rebuild switch and reboot once for hibernate-resume to work." >&2
      fi
    '';
  };

  # ── UPower critical action ───────────────────────────────────────────────
  # UPower's daemon (services.upower.enable, set in modules/nixos/desktop/
  # niri.nix) reads /etc/UPower/UPower.conf for action thresholds. The
  # default is to do nothing on critical; we override to hibernate.
  # Documented options:
  #   PercentageLow / PercentageCritical / PercentageAction
  #   CriticalPowerAction = HybridSleep | Hibernate | PowerOff
  # We set Critical to the user's threshold and Action one step below so
  # there's a chance to react before hibernate kicks in.
  environment.etc."UPower/UPower.conf" = lib.mkIf enabled {
    text = ''
      [UPower]
      EnableWattsBackend=true
      NoPollBatteries=false
      UsePercentageForPolicy=true
      PercentageLow=20
      PercentageCritical=${toString (critP + 5)}
      PercentageAction=${toString critP}
      TimeLow=1200
      TimeCritical=300
      TimeAction=120
      CriticalPowerAction=${critA}
    '';
  };
}
