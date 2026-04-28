{ config, lib, variables, ... }:
let cfg = variables.audio.pipewire or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  security.rtkit.enable = true;
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = lib.mkDefault false;
    wireplumber.extraConfig."99-volume-limit" = {
      "monitor.alsa.rules" = [{
        matches = [{ "node.name" = "~alsa_output.*"; }];
        actions.update-props = {
          # Allow volume up to 150% (1.5) via the volume slider/keybinds.
          "channelmix.max-volume" = 1.0;
        };
      }];
    };
  };
}
