# Add `idled` to pkgs from packages/idled/. This is a first-party tool with
# no upstream because there isn't a packaged daemon that reads /dev/input
# directly to feed wayland-independent idle detection. See
# packages/idled/src/main.rs for the full why.
#
# Retirement condition: delete this file (and its entry in ./default.nix)
# once smithay ext_idle_notifier_v1 issue #1892 is fixed AND niri picks up
# the fix, so swayidle/stasis/hypridle on niri can be trusted again.
final: prev: {
  idled = final.callPackage ../packages/idled { };
}
