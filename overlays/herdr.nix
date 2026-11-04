# herdr — terminal workspace manager / multiplexer for AI coding agents.
#
# WHY THIS EXISTS
# ---------------
# Not in nixpkgs (checked 2026-11-03: `nixpkgs#herdr` does not resolve).
# Upstream ships a flake, but it builds from source with a pinned Rust
# 1.96.1 toolchain (via rust-overlay) plus Zig 0.16 for the vendored
# libghostty-vt; nixpkgs has Rust 1.95. Taking that on means a new flake
# input, a toolchain input and a long cold build on every host.
#
# The official release binaries are a single self-contained executable
# (the Linux ones are static-pie, so no autoPatchelf and no runtime
# closure), published with sha256 digests for each platform. Packaging
# those is a ~20-line fetchurl: reproducible, tiny, and builds in seconds.
# The Windows zip is NOT handled here — Scoop's `main` bucket carries
# herdr and flake-modules/windows installs it from there.
#
# The binary is not stripped: macOS code signatures break if the Mach-O
# is rewritten, and the Linux binary is only a few MiB anyway.
#
# UPDATING
# --------
# Bump `version`, then refresh the four hashes from the release's asset
# digests (`gh api repos/herdrdev/herdr/releases/latest --jq
# '.assets[]|"\(.name) \(.digest)"'`) converted with
# `nix hash convert --hash-algo sha256 --to sri <hex>`. The Windows
# copy updates itself through Scoop (its autoupdate tracks the same
# release), so keep this in step by hand.
#
# RETIRE WHEN
# -----------
# nixpkgs packages herdr (delete this file and drop the entry from
# overlays/default.nix — the attribute name matches, so nothing else
# changes), OR herdr is dropped from the daily workflow.
final: prev:
let
  version = "0.9.5";

  assets = {
    x86_64-linux = {
      name = "herdr-linux-x86_64";
      hash = "sha256-FNnovItKngEY13wyJm921GHwm0A0LrI3UpYL2J9Zkp0=";
    };
    aarch64-linux = {
      name = "herdr-linux-aarch64";
      hash = "sha256-F9dTby2lCFlSNoDvJ53/ysjkojX05G/o2mwuxEFBiXw=";
    };
    x86_64-darwin = {
      name = "herdr-macos-x86_64";
      hash = "sha256-X7CpCOx/Z0Xj4kVziwa/rVbEY5HDkas8CVX76tAfE2k=";
    };
    aarch64-darwin = {
      name = "herdr-macos-aarch64";
      hash = "sha256-+3fCIyoFqANUITgsiUOS9BdOTjihjkivPdApAVfDp+I=";
    };
  };

  asset = assets.${prev.stdenv.hostPlatform.system} or null;
in
{
  herdr =
    if asset == null then
      throw "herdr: no release binary for ${prev.stdenv.hostPlatform.system}"
    else
      prev.stdenvNoCC.mkDerivation {
        pname = "herdr";
        inherit version;

        src = prev.fetchurl {
          url = "https://github.com/herdrdev/herdr/releases/download/v${version}/${asset.name}";
          inherit (asset) hash;
        };

        dontUnpack = true;
        dontStrip = true;

        installPhase = ''
          runHook preInstall
          install -Dm755 $src $out/bin/herdr
          runHook postInstall
        '';

        meta = {
          description = "Terminal workspace manager for AI coding agents";
          homepage = "https://herdr.dev";
          license = prev.lib.licenses.asl20;
          mainProgram = "herdr";
          platforms = builtins.attrNames assets;
          sourceProvenance = [ prev.lib.sourceTypes.binaryNativeCode ];
        };
      };
}
