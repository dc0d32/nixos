# Face unlock — turns on howdy + IR emitter calibration + camera
# autodetect on top of the biometrics baseline.
#
# Why split out: howdy pulls a ~1.2 GiB closure (TensorFlow, dlib,
# the face-recognition model files) and the IR-emitter/v4l2 stack
# only makes sense on laptops with a real IR camera. Hosts that
# just want fingerprint auth (or none) skip this.
#
# Known-broken hardware (as of 2026-05; revisit when linux-surface
# camera support lands):
#   - Surface Laptop 3 (Intel Ice Lake): the IR camera is present
#     but not exposed via v4l2 by the linux-surface kernel. The RGB
#     camera works, but RGB-only face unlock is photo-bypassable
#     and unreliable in low light, so it's not worth the closure
#     cost. Use fingerprint (Business SKU only — power button) or
#     password instead. See
#     https://github.com/linux-surface/linux-surface/issues?q=IR+camera
#   - Any host where `v4l2-ctl --list-devices` doesn't show a node
#     reporting "Infrared" / "IR" in its Card type: the
#     howdy-camera-autodetect oneshot will give up and leave howdy
#     pointed at the static fallback /dev/video2, which probably
#     isn't the right device.
#
# Cross-module signal (canonical pattern, mirrors
# flake-modules/surface.nix ↔ flake-modules/surface-kernel.nix):
#
#   - flake-modules/biometrics.nix declares the NixOS-level option
#     `biometrics.face` (default false) and gates howdy / IR / PAM
#     contributions on it.
#   - This module sets `biometrics.face = mkDefault true`.
#
# Importing face-unlock.nix WITHOUT also importing biometrics.nix
# is a misconfiguration (the option won't be declared and the
# evaluator will reject the assignment). The egghead wizard always
# includes biometrics when the `face-unlock` feature is selected;
# hand-written host bridges should import both.
#
# Retire when: face unlock is no longer wanted on any host, or the
# howdy closure shrinks enough (e.g. ships pre-quantized models)
# that gating it stops being worthwhile, or the biometrics module
# grows enough sub-features that a richer scheme replaces this one.
{
  flake.modules.nixos.face-unlock = { lib, ... }: {
    biometrics.face = lib.mkDefault true;
  };
}
