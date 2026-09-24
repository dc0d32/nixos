# OpenCode's Bun-compiled binary needs an ad-hoc signature on recent macOS.
#
# WHY THIS EXISTS
# ---------------
# nixpkgs' OpenCode 1.15.10 runs the freshly compiled Darwin binary before it
# has been signed. macOS kills it with SIGKILL, so the package fails during its
# integrated smoke test. Even if that test is skipped, wrapping or stripping
# the binary invalidates its original signature.
#
# This backports NixOS/nixpkgs#550458: skip the pre-signing smoke test, sign
# the final wrapped binary, and keep the signed Mach-O file from being stripped.
# Linux is left unchanged.
#
# RETIREMENT CONDITION
# --------------------
# Delete this file and its overlays/default.nix entry when nixpkgs includes
# NixOS/nixpkgs#550458 (OpenCode >= 1.18.16).
final: prev:
let
  affectedVersion = "1.15.10";
in
{
  opencode =
    if !prev.stdenv.hostPlatform.isDarwin then
      prev.opencode
    else if prev.opencode.version != affectedVersion then
      throw ''
        overlays/opencode-darwin.nix targets OpenCode ${affectedVersion},
        but nixpkgs now provides ${prev.opencode.version}.

        Check whether nixpkgs includes NixOS/nixpkgs#550458. If it does,
        delete this overlay and its overlays/default.nix entry.
      ''
    else
      prev.opencode.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
          final.darwin.binutils-unwrapped
          final.darwin.sigtool
        ];

        postPatch = (old.postPatch or "") + ''
          substituteInPlace packages/opencode/script/build.ts \
            --replace-fail \
            'if (item.os === process.platform && item.arch === process.arch && !item.abi)' \
            'if (false)'
        '';

        postInstall = ''
          codesign --force --sign - $out/bin/.opencode-wrapped
        '' + (old.postInstall or "");

        dontStrip = true;
      });
}
