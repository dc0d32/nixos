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
          # Cap output volume at 100% (1.0) to prevent digital clipping
          # via the volume slider/keybinds. Raise (e.g. 1.5 for 150%) only
          # if you trust your downstream gain staging.
          "channelmix.max-volume" = 1.0;
        };
      }];
    };
  };
}
