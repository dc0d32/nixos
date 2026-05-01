# Bluetooth — BlueZ stack on the NixOS side, blueman applet + audio
# codecs on the home-manager side, plus a cross-module signal so other
# dendritic modules (quickshell's bar) can adapt.
#
# Cross-class footprint:
#   - flake.modules.nixos.bluetooth — hardware.bluetooth (BlueZ) with
#     powerOnBoot + Experimental (so BlueZ exposes the
#     org.bluez.Battery1 interface for headset battery levels), a
#     polkit JS rule letting wheel users drive bluez/blueman without
#     password prompts, system packages bluez + bluez-tools so
#     `bluetoothctl` is available to root and to quickshell's QML
#     monitor process, and a wireplumber bluetooth config block
#     enabling the Hands-Free Profile (HFP) and the high-bitrate
#     A2DP codecs (LDAC, aptX, aptX-HD).
#   - flake.modules.homeManager.bluetooth — installs blueman so the
#     graphical pairing wizard / device manager is available as an
#     escape hatch when quickshell's flyout can't handle a corner
#     case (e.g. unusual PIN flows, exotic services). Autostarts
#     blueman-applet via a user systemd unit so its tray icon lands
#     in quickshell's SystemTray automatically.
#
# Pattern A: hosts opt in by importing this module on either class.
# WSL doesn't get bluetooth; ah-1 (NAS) doesn't either.
#
# Top-level options:
#   - bluetooth.enable — read-only signal; true iff this module is
#     imported on this host. Set by mkDefault inside the module body
#     so other modules (e.g. quickshell's bluetooth chip) can read
#     the flag without coupling to a host-level toggle. Mirrors the
#     pattern used in flake-modules/biometrics.nix.
#
# User permissions: BlueZ does not ship a `bluetooth` Unix group;
# upstream-recommended access control is via polkit. The polkit JS
# rule below grants pairing/connecting/discovery to any locally-
# logged-in active user (subject.local && subject.active) — i.e.
# anyone sitting at the laptop, including the kid accounts on
# pb-t480. Bluetooth is treated as a per-seat hardware control like
# the volume keys, not a privileged operation.
#
# Retire when: BlueZ + wireplumber bluetooth ship sane upstream
#   defaults that match this config (HFP + LDAC/aptX enabled out of
#   the box, Battery1 stable, polkit rules for wheel by default), OR
#   we move off BlueZ entirely.
{ lib, config, ... }:
{
  options.bluetooth = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Read-only signal: true iff the bluetooth module is imported on
        this host. Other dendritic modules (quickshell's bar chip,
        future per-host UI hints) inspect this to decide whether to
        render bluetooth UI. Don't set this manually — import
        flake-modules/bluetooth.nix to enable bluetooth; the module
        sets this flag itself.
      '';
    };
  };

  config = {
    # Importing this module IS enabling bluetooth. Publish that fact
    # as a signal so dependent modules (quickshell bar chip) can
    # read it.
    bluetooth.enable = lib.mkDefault true;

    # ── NixOS side ──────────────────────────────────────────────────
    flake.modules.nixos.bluetooth = { pkgs, lib, ... }: {
      hardware.bluetooth = {
        enable = true;
        # Bring the controller up at boot. Without this the user has
        # to run `bluetoothctl power on` after every reboot before
        # any device will connect.
        powerOnBoot = true;
        # Experimental = on exposes org.bluez.Battery1 for headset
        # battery levels (read by quickshell's bluetooth chip via
        # `bluetoothctl info <mac>`'s `Battery Percentage` line) and
        # enables LE Privacy / advertising features that some
        # earbuds / trackers expect. Stable on BlueZ ≥ 5.65.
        settings.General.Experimental = true;
      };

      # Polkit rule: let any local active-session user drive bluez
      # and blueman without a password prompt. Without this, every
      # pairing / connect / scan-toggle from quickshell's flyout
      # pops a polkit auth dialog (which would route through
      # hyprpolkitagent to the face/finger biometric stack — annoying
      # for a routine bluetooth toggle). The `subject.local &&
      # subject.active` test is the standard polkit idiom for
      # "physically present at this seat" — covers wheel users on
      # pb-x1 and the kid accounts on pb-t480 alike. Remote / inactive
      # sessions still hit the prompt.
      #
      # The two action prefixes cover BlueZ direct (org.bluez.*) and
      # blueman's gdbus wrapper (org.blueman.*). Rule format is the
      # modern polkit JS rules.d API; the deprecated .pkla loader is
      # going away in polkit ≥ 0.121.
      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if ((action.id.indexOf("org.bluez.") === 0
               || action.id.indexOf("org.blueman.") === 0)
              && subject.local && subject.active) {
            return polkit.Result.YES;
          }
        });
      '';

      # bluez-tools provides `bt-adapter`, `bt-agent`, `bt-device`
      # etc. for scripting; bluez itself supplies `bluetoothctl`,
      # which is what BluetoothState.qml shells out to. Both are
      # needed at the system level so they exist on $PATH for
      # quickshell's Process { command } invocations.
      environment.systemPackages = [
        pkgs.bluez
        pkgs.bluez-tools
      ];

      # ── Wireplumber bluetooth audio config ─────────────────────
      # Enable HFP (Hands-Free Profile) for headset mics, plus the
      # high-bitrate A2DP codecs (LDAC, aptX, aptX-HD, AAC). On
      # nixpkgs' wireplumber-0.5+, bluetooth config lives under the
      # `bluetooth` subtree of `services.pipewire.wireplumber.
      # extraConfig`. The keys mirror upstream wireplumber's
      # /usr/share/wireplumber/bluetooth.lua.d/50-bluez-config.lua
      # but in JSON form (wireplumber's new SPA-JSON config loader).
      #
      # `bluez5.enable-sbc-xq = true` enables SBC-XQ, a higher-
      # bitrate variant of the mandatory SBC codec; safe fallback for
      # devices that don't speak LDAC/aptX.
      # `bluez5.enable-msbc = true` enables mSBC for HFP wideband
      # voice (16 kHz instead of telephony-grade 8 kHz). Most modern
      # headsets support it.
      # `bluez5.roles = [ "a2dp_sink" "a2dp_source" "hfp_hf"
      # "hfp_ag" "bap_sink" "bap_source" ]` advertises us as both an
      # audio sink/source and a hands-free unit (so headsets with
      # mics work) and as a LE Audio (BAP) endpoint where the
      # firmware supports it.
      services.pipewire.wireplumber.extraConfig."51-bluez-config" = {
        "monitor.bluez.properties" = {
          "bluez5.enable-sbc-xq" = true;
          "bluez5.enable-msbc" = true;
          "bluez5.enable-hw-volume" = true;
          "bluez5.roles" = [
            "a2dp_sink"
            "a2dp_source"
            "bap_sink"
            "bap_source"
            "hfp_hf"
            "hfp_ag"
          ];
          # Codec preference order (highest quality first). PipeWire
          # negotiates the first codec the peer also supports.
          "bluez5.codecs" = [
            "ldac"
            "aptx_hd"
            "aptx"
            "aac"
            "sbc_xq"
            "sbc"
          ];
        };
      };
    };

    # ── home-manager side ───────────────────────────────────────────
    flake.modules.homeManager.bluetooth = { pkgs, ... }: {
      # blueman = full graphical pairing wizard + device manager.
      # Reaches the system bluez via D-Bus (no extra config needed).
      # The applet binary `blueman-applet` populates the system tray
      # with a connect/disconnect menu; quickshell's SystemTray
      # picks it up automatically.
      home.packages = [ pkgs.blueman ];

      # Autostart blueman-applet under the graphical session so the
      # tray icon is there as soon as the bar comes up. Started as a
      # systemd user unit (rather than via niri spawn-at-startup) to
      # keep the lifecycle consistent with our other tray daemons
      # (e.g. easyeffects in flake-modules/audio.nix). Restart on
      # exit so a tray crash doesn't permanently lose the icon.
      systemd.user.services.blueman-applet = {
        Unit = {
          Description = "Blueman applet (Bluetooth tray icon)";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          Type = "exec";
          ExecStart = "${pkgs.blueman}/bin/blueman-applet";
          Restart = "on-failure";
          RestartSec = 3;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
