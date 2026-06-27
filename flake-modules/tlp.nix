# TLP — the single, proven power manager for this flake's laptops.
#
# Why TLP (and why it replaced the PPD/tuned/idled churn)
# ------------------------------------------------------
# Power management here had drifted into three half-overlapping mechanisms
# with nobody actually doing AC↔battery switching:
#   * power-profiles-daemon was enabled (niri.nix) but PPD 0.30 does NOT
#     switch profiles on its own — its "BatteryAware" only swaps the
#     intel_pstate EPP hint within the balanced profile (verified against
#     the 0.30 source; see flake-modules/battery.nix).
#   * nixos-hardware wanted TLP on these ThinkPads but suppressed it
#     (`tlp.enable = mkDefault (!power-profiles-daemon.enable)`).
#   * The actual "conserve on battery" feature (idled → a hand-rolled
#     battery-power-saver timer) had been deleted outright.
# TLP is the decade-old, ThinkPad-grade standard and does automatic
# AC↔battery switching natively (EPP, turbo, PCIe ASPM, USB autosuspend,
# runtime PM, Wi-Fi power save). Adopting it collapses the whole mess into
# one battle-tested daemon and is what nixos-hardware already wants here.
#
# Scope: imported by the LAPTOP bridges (pb-x1, pb-t480) only, NOT the
# nixos-workstation bundle — the m-pc desktop has no battery and wants no
# laptop power knobs (it relies on the kernel governor + thermald). PPD is
# dropped fleet-wide (niri.nix no longer enables it), so nothing on niri
# consumes `powerprofilesctl` and there is no TLP↔PPD conflict.
#
# Division of labour with battery.nix: this module owns *power policy*
# (what to do on AC vs battery). flake-modules/battery.nix still owns the
# *charge thresholds* (sysfs) and *hibernate-on-critical* (UPower). TLP
# only manages charge thresholds if START/STOP_CHARGE_THRESH_* are set —
# they intentionally are NOT set here, so battery.nix remains the single
# owner of thresholds and the two never fight.
#
# Settings rationale: we lean on TLP's vetted defaults and only pin the
# few knobs that express intent. In particular EPP is balance_performance
# on AC and balance_power on battery — deliberately NOT "power" (EPP=power
# is what pinned the i7-8650U near 0.9 GHz and started this whole saga);
# balance_power still turbos, just biased toward efficiency.
#
# Retire when: the flake stops having bare-metal laptops, OR a future
#   kernel/daemon supersedes TLP for ThinkPad-class power management.
{
  flake.modules.nixos.tlp = { ... }: {
    services.tlp = {
      enable = true;
      settings = {
        # Energy-Performance Preference (intel_pstate HWP). Responsive on
        # AC, efficient-but-not-crippled on battery.
        CPU_ENERGY_PERF_POLICY_ON_AC = "balance_performance";
        CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_power";

        # Keep turbo available on both so bursts stay snappy; drop only the
        # always-on dynamic boost on battery for efficiency.
        CPU_BOOST_ON_AC = 1;
        CPU_BOOST_ON_BAT = 1;
        CPU_HWP_DYN_BOOST_ON_AC = 1;
        CPU_HWP_DYN_BOOST_ON_BAT = 0;

        # Wi-Fi power saving: full speed on AC, save on battery.
        WIFI_PWR_ON_AC = "off";
        WIFI_PWR_ON_BAT = "on";

        # PCIe ASPM: kernel default on AC, aggressive on battery.
        PCIE_ASPM_ON_AC = "default";
        PCIE_ASPM_ON_BAT = "powersupersave";
      };
    };
  };
}
