{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.idle or { enable = true; };
  lockAfter   = cfg.lockAfter   or 900;
  dpmsAfter   = cfg.dpmsAfter   or 1020;
  suspendAfter = cfg.suspendAfter or 1800;
  # dpms timeout in stasis is relative to lock, not to idle start
  dpmsRel    = dpmsAfter - lockAfter;
  suspendRel = suspendAfter - lockAfter;
in
lib.mkIf (cfg.enable) {
  home.packages = with pkgs; [ brightnessctl stasis ];

  xdg.configFile."stasis/stasis.rune" = {
    force = true;
    text = ''
      @author "p"
      @description "Stasis config for niri + quickshell"

      default:
        monitor_media false
        inhibit_apps = ["mpv", "vlc", "chromium"]
        # debounce: how long input must be absent before idle countdown starts.
        # Set high to compensate for niri not resetting ext_idle_notifier_v1
        # on all input events (e.g. Electron windows losing focus briefly).
        debounce_seconds = 300

        lock_screen:
          timeout = ${toString lockAfter}
          command = "quickshell ipc call lock lock"
        end

        dpms:
          timeout = ${toString dpmsRel}
          command = "niri msg action power-off-monitors"
          resume-command = "niri msg action power-on-monitors"
        end

        suspend:
          timeout = ${toString suspendRel}
          command = "systemctl suspend"
        end
      end
    '';
  };

  programs.niri.settings.spawn-at-startup = lib.mkAfter [
    { command = [ "stasis" ]; }
  ];
}
