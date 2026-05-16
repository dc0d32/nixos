# egghead-tui — TypeScript + Ink front-end for the egghead wizard.
#
# Builds the TUI binary via buildNpmPackage:
#   1. `npm ci` populates node_modules into the nix store.
#   2. `npm run build` (tsc) transpiles src → dist.
#   3. `npm prune --omit=dev` strips devDeps so the closure stays slim.
#   4. The package lands at $out/lib/node_modules/egghead-tui/.
#   5. A makeWrapper-built shim in $out/bin/egghead-tui runs
#      `node $out/lib/.../dist/index.js` with EGGHEAD_BASH_SCRIPT
#      pre-set to the in-store path of the bash wizard.
#
# The bash script (scripts/egghead.sh) is the engine: the TUI is a
# pretty front-end that sets EGGHEAD_* env vars and execs bash with
# --non-interactive. Keeping a single source of truth for what gets
# written to disk avoids drift between the two UIs.
#
# Retire when the bash script is also rewritten in TS and the TUI
# implements its own bridge/hwconfig/commit/install pipeline directly.
{ lib
, buildNpmPackage
, nodejs_22
, makeWrapper
, bashScript      # path to scripts/egghead.sh, passed in from egghead.nix
, runtimeInputs   # PATH for bash: git, util-linux, nix, etc.
}:

buildNpmPackage {
  pname = "egghead-tui";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  # Refresh whenever package-lock.json changes (npmDepsHash mismatch
  # → builder prints the correct hash; paste it back here).
  npmDepsHash = "sha256-8bAsTbeQ1InYupkN0ctInGUlX/N5LM2tfrGMCRgEDb4=";

  nodejs = nodejs_22;

  nativeBuildInputs = [ makeWrapper ];

  # buildNpmPackage's default install moves the whole working tree to
  # $out/lib/node_modules/<name>/. We then post-install a wrapper bin.
  postInstall = ''
    mkdir -p $out/bin
    makeWrapper ${nodejs_22}/bin/node $out/bin/egghead \
      --add-flags $out/lib/node_modules/egghead-tui/dist/index.js \
      --set EGGHEAD_BASH_SCRIPT ${bashScript} \
      --prefix PATH : ${lib.makeBinPath runtimeInputs}
  '';

  meta = with lib; {
    description = "TUI installer wizard for this NixOS flake (Ink front-end over scripts/egghead.sh)";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "egghead";
  };
}
