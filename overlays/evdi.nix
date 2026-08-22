# EVDI 1.15.0 adds the DRM API probes required to build against Linux 7.2.
#
# WHY THIS EXISTS
# ---------------
# nixpkgs currently packages EVDI 1.14.15, which fails against
# linuxPackages_latest (Linux 7.2) after the DRM atomic callbacks changed from
# `drm_atomic_state` to `drm_atomic_commit`. Upstream fixed that incompatibility
# in 1.15.0, but nixpkgs has not yet picked up the release.
#
# Only linuxPackages_latest is overridden: that is the package set selected by
# the workstation bundle and therefore the one whose EVDI build is broken.
# The version guard makes this a no-op as soon as nixpkgs catches up.
#
# RETIREMENT CONDITION
# --------------------
# Delete this file and its overlays/default.nix entry once nixpkgs provides
# EVDI 1.15.0 or newer.
final: prev:
let
  fixedVersion = "1.15.0";
in
{
  linuxPackages_latest =
    if prev.lib.versionOlder prev.linuxPackages_latest.evdi.version fixedVersion then
      prev.linuxPackages_latest.extend
        (_: linuxPrev: {
          evdi = linuxPrev.evdi.overrideAttrs (_: {
            version = fixedVersion;
            src = final.fetchurl {
              url = "https://github.com/DisplayLink/evdi/archive/refs/tags/v${fixedVersion}.tar.gz";
              hash = "sha256-wZzREgtDoNiOkc3Yk7WSpWuakE6tJeqCmetLRR9kmJk=";
            };
            # 1.15 replaced distro/version conditionals with compile probes, so
            # nixpkgs' 1.14-specific /etc/os-release substitution no longer
            # matches anything.
            prePatch = "";
            # The 1.15 probe is a false negative under Linux 7.2's build
            # flags; testing the helper macro directly avoids redefining it.
            postPatch = ''
              substituteInPlace module/evdi_debug.h \
                --replace-fail '#ifndef EVDI_HAVE_KZALLOC_OBJ' '#ifndef kzalloc_obj'
            '';
          });
        })
    else
      prev.linuxPackages_latest;
}
