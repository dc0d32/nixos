# Build Unix WezTerm from the shared recent-nightly pin rather than nixpkgs'
# older source, keeping the GUI, mux server and terminfo on the same revision.
# Retire when nixpkgs provides this revision or newer with equivalent packaging.
{ src }:
final: prev:
let
  pin = import ./wezterm-pin.nix;
in
assert src.rev == pin.revision;
assert src.narHash == pin.sourceHash;
prev.wezterm.overrideAttrs (finalAttrs: old: {
  version = pin.version;

  inherit src;

  cargoHash = pin.cargoHash;

  # buildRustPackage captures the original cargoHash before overrideAttrs.
  cargoDeps = final.rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    hash = finalAttrs.cargoHash;
  };

  buildInputs = (old.buildInputs or [ ])
    ++ final.lib.optional final.stdenv.hostPlatform.isDarwin final.libiconv;

  nativeBuildInputs = (old.nativeBuildInputs or [ ])
    ++ final.lib.optional final.stdenv.hostPlatform.isDarwin final.rcodesign;

  # The inherited finalAttrs-aware hook writes the updated version to .tag.
  # Upstream also skips SSH integration tests that cannot exchange keys.
  postPatch = (old.postPatch or "") + ''
    rm -rf wezterm-ssh/tests
  '';

  preFixup =
    if final.stdenv.hostPlatform.isDarwin then ''
      app="$out/Applications/WezTerm.app"
      mkdir -p "$out/Applications"
      cp -R assets/macos/WezTerm.app "$app"
      # Upstream omits MetalANGLE; the native GUI uses CGL instead.
      rm "$app"/*.dylib
      mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
      cp -R assets/shell-integration/. "$app/Contents/Resources/"
      cp -R assets/shell-completion "$app/Contents/Resources/"
      cp -R ${finalAttrs.passthru.terminfo}/share/terminfo "$app/Contents/Resources/"
      for command in wezterm wezterm-gui wezterm-mux-server strip-ansi-escapes; do
        mv "$out/bin/$command" "$app/Contents/MacOS/$command"
        ln -s "$app/Contents/MacOS/$command" "$out/bin/$command"
      done
    '' else old.preFixup or "";

  # Strip/install-name fixups must finish before sealing the executables and app.
  postFixup = (old.postFixup or "") + final.lib.optionalString final.stdenv.hostPlatform.isDarwin ''
    app="$out/Applications/WezTerm.app"
    for command in wezterm wezterm-gui wezterm-mux-server strip-ansi-escapes; do
      rcodesign sign "$app/Contents/MacOS/$command"
    done
    rcodesign sign "$app"
  '';

  passthru = (old.passthru or { }) // {
    inherit pin;
    headless = final.rustPlatform.buildRustPackage {
      pname = "wezterm-headless";
      inherit (finalAttrs) version src postPatch cargoHash cargoDeps auditable meta;

      nativeBuildInputs = [ final.pkg-config ];
      buildInputs = [ final.openssl ];

      cargoBuildFlags = [
        "--package"
        "wezterm"
        "--package"
        "wezterm-mux-server"
      ];

      doCheck = false;

      postInstall = ''
        install -Dm644 assets/shell-integration/wezterm.sh -t $out/etc/profile.d
        install -Dm644 ${finalAttrs.passthru.terminfo}/share/terminfo/w/wezterm -t $out/share/terminfo/w
      '';
    };

    terminfo = final.runCommand "wezterm-terminfo-${finalAttrs.version}"
      { nativeBuildInputs = [ final.ncurses ]; }
      ''
        mkdir -p $out/share/terminfo $out/nix-support
        tic -x -o $out/share/terminfo ${finalAttrs.src}/termwiz/data/wezterm.terminfo
      '';
  };
})
