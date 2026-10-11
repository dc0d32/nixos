# Thrift's bundled test suite fails to compile on recent macOS SDKs.
#
# WHY THIS EXISTS
# ---------------
# nixpkgs builds thrift with `-DBUILD_TESTING:BOOL=TRUE`, so its C++ test
# programs are compiled as part of the normal build (not just `checkPhase`).
# Those tests vendor the Catch framework, which no longer compiles under the
# Apple SDK 26 libcxx: Catch's RandomNumberGenerator trips a libcxx
# `static_assert` (`__libcpp_random_is_valid_urng`), and its debugger trap
# emits an x86-only `int $3` on aarch64. The thrift *library* is unaffected —
# only the tests break — but a compile failure in the test target fails the
# whole build, which cascades through arrow-cpp -> pyarrow -> visidata.
#
# We flip BUILD_TESTING off (and keep doCheck false) on Darwin only, so the
# library still builds. Linux is left untouched.
#
# RETIREMENT CONDITION
# --------------------
# Delete this file and its overlays/default.nix entry once nixpkgs' thrift
# builds on aarch64-darwin under the current Apple SDK without this flag
# (either thrift stops compiling tests by default, or upstream fixes the
# vendored Catch for libcxx). Verify with:
#   nix build .#homeConfigurations.'p@pb-mb'.activationPackage
final: prev:
{
  thrift =
    if !prev.stdenv.hostPlatform.isDarwin then
      prev.thrift
    else
      prev.thrift.overrideAttrs (old: {
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DBUILD_TESTING:BOOL=FALSE" ];
        doCheck = false;
      });
}
