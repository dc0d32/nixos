# DisplayLink docks (evdi kernel module + DisplayLinkManager userspace).
#
# WHY THIS EXISTS
# ---------------
# DisplayLink docks — e.g. the Lenovo ThinkPad Hybrid USB-C with USB-A
# Dock (USB ID 17e9:6015) used with pb-x1 / pb-t480 — do not carry video
# over DisplayPort alt-mode or a Thunderbolt PCIe tunnel. Video is
# compressed and shipped over plain USB bulk transfers to a DL-6xxx ASIC
# in the dock. Nothing in a stock kernel claims that USB interface, so
# without this module the dock's USB hub, ethernet and audio all work
# perfectly while the external monitors stay completely dead — which is
# exactly the confusing half-working state that made the dock experience
# on pb-t480 so bad.
#
# Making it work needs two cooperating halves:
#   1. `evdi` — a GPL/LGPL/MIT kernel module that exposes a virtual DRM
#      device. The compositor renders into it like any other output.
#   2. `DisplayLinkManager` — a proprietary userspace daemon that reads
#      those frames back out of evdi, compresses them, and pushes them
#      over USB to the dock.
# Neither is useful without the other.
#
# WHY NOT nixpkgs' hardware/video/displaylink.nix
# -----------------------------------------------
# That module is X11-shaped. It is gated on
# `services.xserver.videoDrivers` containing "displaylink", and its body
# emits an `xorg.conf.d` OutputClass stanza, sets
# `services.xserver.externallyConfiguredDrivers`, and hangs an
# `xrandr --setprovideroutputsource 1 0` off
# `services.xserver.displayManager.sessionCommands`.
#
# These hosts are Wayland-only (niri; see flake-modules/niri.nix), so
# importing it would mean switching on `services.xserver` — dragging in
# an X server and a display-manager session path we deliberately do not
# run — purely to reach three lines that are Wayland-relevant. The
# Wayland-relevant parts are reproduced faithfully below; the X11 parts
# are dropped, not reimplemented.
#
# HOW IT COMES UP
# ---------------
# `dlm.service` is NOT `wantedBy` anything. The udev rule shipped in the
# displaylink package starts it on demand:
#
#   ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="17e9",
#     ATTR{bInterfaceClass}=="ff", ATTR{bInterfaceProtocol}=="03",
#     TAG+="systemd", ENV{SYSTEMD_WANTS}="dlm.service"
#
# So the daemon only runs while a DisplayLink device is attached, and it
# starts on both hotplug and coldplug (udev replays `add` at boot). That
# is the behaviour we want on a laptop that is docked maybe half the
# time — no idle proprietary daemon when undocked.
#
# NOTE ON THE PROPRIETARY BLOB
# ----------------------------
# `pkgs.displaylink` is unfree and non-redistributable. overlays/
# displaylink.nix makes it fetch itself rather than requiring a manual
# `nix-prefetch-url` on every host — see that file for the rationale and
# the caching caveat. `evdi` itself is free software and is already in
# cache.nixos.org, so only the small userspace blob is built locally.
#
# FIRST DEPLOYMENT NEEDS A REBOOT
# -------------------------------
# `boot.extraModulePackages` only lands in the *booted* system's module
# tree. After the first `nixos-rebuild switch` that adds this module,
# `/run/current-system/kernel-modules` contains evdi.ko but
# `/run/booted-system/kernel-modules` — which is what `/lib/modules`,
# and therefore modprobe, resolves to — does not. So
# `systemd-modules-load` logs "Failed to find module 'evdi'", the
# module never loads, and the dock's monitors stay dark even though
# dlm.service is happily running.
#
# Reboot after the first switch. To verify without one (same kernel
# version only):
#
#     sudo modprobe -d /run/current-system/kernel-modules evdi
#     sudo systemctl restart dlm.service
#
# RETIREMENT CONDITION
# --------------------
# Delete this file when either:
#   * every dock in the fleet does video over DP alt-mode or Thunderbolt
#     (i.e. no DisplayLink silicon left), so nothing imports this; OR
#   * the kernel gains an in-tree driver for DL-6xxx video that does not
#     need a proprietary userspace daemon, at which point this collapses
#     to a `boot.kernelModules` one-liner somewhere else.
{ ... }:
{
  flake.modules.nixos.displaylink = { config, pkgs, ... }:
    let
      # Must be built against the *running* kernel, so take it from
      # kernelPackages rather than a bare `pkgs.evdi`. Hosts here track
      # linuxPackages_latest (flake-modules/kernel-latest.nix), so this
      # follows kernel bumps automatically.
      evdi = config.boot.kernelPackages.evdi;

      # The userspace daemon links against the very same evdi tree it
      # will talk to; nixpkgs exposes that as an override precisely so
      # the two cannot drift apart.
      displaylink = pkgs.displaylink.override { inherit evdi; };
    in
    {
      boot.extraModulePackages = [ evdi ];

      # evdi creates no DRM devices until DisplayLinkManager asks it to
      # (module param `initial_device_count` defaults to 0), so loading
      # it unconditionally costs nothing while undocked and avoids a
      # modprobe race on the udev-triggered daemon start.
      boot.kernelModules = [ "evdi" ];

      # Ships 99-displaylink.rules, which is what actually starts
      # dlm.service. Without this the service below never runs.
      services.udev.packages = [ displaylink ];

      systemd.services.dlm = {
        description = "DisplayLink Manager Service";

        # Ordering only — harmless if the unit is absent, which it is on
        # a niri host with no display manager in the X11 sense.
        after = [ "systemd-udev-settle.service" ];

        # Deliberately no `wantedBy`: the udev rule owns the lifecycle.
        # Deliberately no `conflicts = [ "getty@tty7.service" ]` either
        # (nixpkgs sets that because X11 historically owned tty7; there
        # is no such conflict under Wayland).

        serviceConfig = {
          ExecStart = "${displaylink}/bin/DisplayLinkManager";
          Restart = "always";
          RestartSec = 5;
          LogsDirectory = "displaylink";
        };
      };

      # DisplayLinkManager needs to be told about suspend explicitly or
      # it wedges on resume with the dock still attached: the USB device
      # re-enumerates underneath it and the daemon keeps pushing frames
      # at a handle that no longer exists. The handshake below is lifted
      # from displaylink-installer.sh — write S, wait for the ack, and
      # write R on the way back up.
      #
      # The guards are NOT cosmetic, and are why this isn't a copy of the
      # nixpkgs module's version. These commands run from the
      # `sleep-actions` unit, which is ordered `before sleep.target`, so
      # anything that fails or blocks here hurts every suspend:
      #   * /tmp/PmMessagesPort_{in,out} are FIFOs created by
      #     DisplayLinkManager. On a host that has never docked since
      #     boot they do not exist, and an unguarded redirect exits
      #     non-zero — failing the unit on every single suspend.
      #   * Opening a FIFO for writing BLOCKS until a reader appears. If
      #     the daemon died leaving a stale FIFO behind, an unguarded
      #     `echo > …_in` would hang the suspend indefinitely. Hence
      #     `timeout`.
      # An undocked laptop must suspend instantly and cleanly, so every
      # step here is best-effort and bounded.
      powerManagement.powerDownCommands = ''
        if [ -p /tmp/PmMessagesPort_in ] && [ -p /tmp/PmMessagesPort_out ]; then
          # Drain any stale bytes left in the pipe from a previous cycle.
          while read -r -n 1 -t 1 _ < /tmp/PmMessagesPort_out; do : ; done || true

          ${pkgs.coreutils}/bin/timeout 5 \
            sh -c 'echo "S" > /tmp/PmMessagesPort_in' || true

          # Bounded wait for the daemon's suspend acknowledgement.
          read -r -n 1 -t 10 _ < /tmp/PmMessagesPort_out || true
        fi
      '';

      powerManagement.resumeCommands = ''
        if [ -p /tmp/PmMessagesPort_in ]; then
          ${pkgs.coreutils}/bin/timeout 5 \
            sh -c 'echo "R" > /tmp/PmMessagesPort_in' || true
        fi
      '';
    };
}
