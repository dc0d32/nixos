{ pkgs, lib, variables, ... }:
let
  cfg = variables.audio.easyeffects or { enable = false; };
in
lib.mkIf cfg.enable {
  home.packages =
    [ pkgs.easyeffects pkgs.calf pkgs.libebur128 pkgs.rnnoise pkgs.deepfilternet pkgs.speexdsp ]
    ++ lib.optional (cfg.enableConvolver or false) pkgs.zita-convolver;
}