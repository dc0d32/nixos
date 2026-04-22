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
  };
}
