# Thunderbolt 3 / 4 device authorization (boltd).
#
# WHY THIS EXISTS
# ---------------
# Thunderbolt bridges PCIe between the host and the peripheral, so a TB
# dock's ethernet, USB controller and any DisplayPort tunnels that ride
# the PCIe link only come up once the device has been *authorized*.
# Modern controllers refuse to do that on their own: both TB domains on
# pb-x1 report
#
#     /sys/bus/thunderbolt/devices/domain{0,1}/security = user
#
# which means "connected devices must be authorized by the user before
# PCIe tunnels are activated". Nothing in this flake used to provide the
# userspace side of that handshake — `boltd` was absent and `boltctl`
# wasn't even installed — so on a TB3/TB4 dock the authorization simply
# never happened and the dock stayed dark and dead.
#
# (Note this is a *different* failure from the DisplayLink dock handled
# in flake-modules/displaylink.nix, which carries video over USB and
# needs no TB authorization at all. A fleet with both kinds of dock
# needs both modules; neither substitutes for the other.)
#
# THE IOMMU FAST PATH — why this is usually zero-touch
# ----------------------------------------------------
# From boltd(8): if the platform supports using the IOMMU to restrict
# DMA to safe regions — advertised as `iommu_dma_protection` on the
# domain — boltd changes behaviour and will *automatically enroll new
# devices with the `iommu` policy and authorize them with no user
# interaction whatsoever*. That is precisely the Windows "Kernel DMA
# Protection" model: the DMA attack that the authorization prompt exists
# to prevent is already mitigated in hardware, so the prompt is dropped.
#
# pb-x1 has this (`iommu_dma_protection` = 1 on both domains; the kernel
# logs "DMAR: Intel-IOMMU force enabled due to platform opt in"), so
# simply running boltd is enough — docks authorize themselves silently.
#
# Older hardware does NOT. The T480 is Alpine Ridge (2018), predating
# Kernel DMA Protection, so it falls back to asking. That is what
# `trustLocalUsers` below is for. Check any given host with:
#
#     boltctl domains          # look for "iommu: yes/no"
#
# RETIREMENT CONDITION
# --------------------
# Delete this file when either:
#   * no host in the fleet has a Thunderbolt port (e.g. everything has
#     moved to USB4-without-TB or DisplayLink docks); OR
#   * the kernel gains in-tree automatic TB authorization gated on IOMMU
#     DMA protection, making a userspace daemon unnecessary.
{ ... }:
{
  flake.modules.nixos.thunderbolt = { config, lib, ... }:
    let
      cfg = config.thunderbolt;
    in
    {
      # Declared inside the NixOS module (not as a flake-parts top-level
      # option) so it is PER-HOST. flake-parts top-level options are
      # shared across every host in the flake, so a top-level
      # `thunderbolt.trustLocalUsers = true` set for pb-t480 would also
      # silently loosen pb-x1. Same reasoning as
      # hardware-hacking.extraUsers — see that module's header.
      options.thunderbolt.trustLocalUsers = lib.mkOption {
        type = lib.types.bool;
        default = false;
        example = true;
        description = ''
          Allow any physically-present (local + active session) user to
          authorize and enroll Thunderbolt devices without an admin
          password.

          Leave this `false` on hosts whose firmware provides IOMMU DMA
          protection: there, boltd already auto-authorizes everything
          with no prompt at all, so the rule would buy nothing while
          still widening the policy. Verify with `boltctl domains`.

          Set it `true` only on pre-DMA-protection hardware (e.g. the
          T480's Alpine Ridge controller) where docking would otherwise
          pop an `auth_admin` prompt that a non-wheel user — such as the
          kid accounts on pb-t480 — cannot possibly satisfy, leaving
          them unable to use a dock at all.

          SECURITY TRADE-OFF: on such a host this permits someone with
          physical access to authorize a malicious Thunderbolt device
          and DMA host memory, without knowing an admin password. A
          logind session stays "active" while the screen is locked, so
          this does apply to a locked, unattended laptop. Accepted on
          the family laptop because the alternative is a dock that
          simply does not work for the people who use it daily.
        '';
      };

      config = {
        # boltd itself (socket/udev-activated by the units and rules the
        # bolt package ships) plus the `boltctl` CLI. On IOMMU-protected
        # hosts this single line is the entire fix.
        services.hardware.bolt.enable = true;

        # Bolt's shipped policy defaults all three actions
        # (org.freedesktop.bolt.{enroll,authorize,manage}) to
        # `auth_admin`. Matching on the `org.freedesktop.bolt.` prefix
        # therefore covers enroll + authorize + manage in one rule.
        #
        # `subject.local && subject.active` is the standard polkit idiom
        # for "physically present at this seat", and is the same test
        # flake-modules/bluetooth.nix uses. Remote and inactive sessions
        # still get the prompt.
        security.polkit.extraConfig = lib.mkIf cfg.trustLocalUsers ''
          polkit.addRule(function (action, subject) {
            if (action.id.indexOf("org.freedesktop.bolt.") === 0
                && subject.local && subject.active) {
              return polkit.Result.YES;
            }
          });
        '';
      };
    };
}
