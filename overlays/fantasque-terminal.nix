# Fantasque Sans Mono terminal face with grid-safe Unicode symbols.
#
# WHY THIS EXISTS
# Fantasque's Nerd Font Mono face deliberately keeps patched icons to one
# terminal cell, but omits Braille spinners, btop's filled triangles, and the
# Unicode clock faces. Core Text and DirectWrite then choose emoji or
# proportional fallback faces whose ink can spill into neighboring cells.
# Keep Fantasque's letterforms and existing Nerd glyphs, filling only those
# missing code points from monospace sources with explicit one- or two-cell
# advances.
#
# RETIRE WHEN
# Fantasque Sans Mono Nerd Font ships these glyphs itself with terminal-safe
# metrics, or every terminal in use supports a configurable, grid-safe symbol
# fallback that also handles emoji-presentation clock characters.
final: prev:
let
  fantasque = prev.nerd-fonts.fantasque-sans-mono;
  caskaydia = prev.nerd-fonts.caskaydia-mono;
  cozette = prev.cozette;
in
{
  fantasque-terminal = prev.stdenvNoCC.mkDerivation {
    pname = "fantasque-terminal";
    inherit (fantasque) version;

    dontUnpack = true;
    nativeBuildInputs = [ prev.fontforge ];

    installPhase = ''
            runHook preInstall

            outDir="$out/share/fonts/truetype/NerdFonts/FantasqueSansM"
            windowsDir="$out/share/windows-fonts"
            mkdir -p "$outDir"
            mkdir -p "$windowsDir"

            for style in Regular Bold Italic BoldItalic; do
              caskStyle="$style"
              cozetteFile=${cozette}/share/fonts/truetype/CozetteVector.ttf
              if [[ "$style" == Bold* ]]; then
                cozetteFile=${cozette}/share/fonts/truetype/CozetteVectorBold.ttf
              fi

              ${prev.fontforge}/bin/fontforge -lang=py -c '
      import fontforge
      import psMat
      import sys

      target_path, symbol_path, clock_path, output_path, windows_path, style = sys.argv[1:]
      target = fontforge.open(target_path)
      symbols = fontforge.open(symbol_path)
      clocks = fontforge.open(clock_path)
      cell = target[0x20].width

      def copy_glyph(source, codepoint, width, x_scale=1.0):
          source.selection.select(codepoint)
          source.copy()
          target.selection.select(codepoint)
          target.paste()
          glyph = target[codepoint]
          if x_scale != 1.0:
              glyph.transform(psMat.scale(x_scale, 1.0))
          glyph.width = width

      symbol_scale = float(cell) / symbols[0x20].width
      for codepoint in [0x25B2, 0x25BC]:
          copy_glyph(symbols, codepoint, cell, symbol_scale)
      for codepoint in range(0x2800, 0x2900):
          copy_glyph(symbols, codepoint, cell, symbol_scale)

      for codepoint in range(0x1F550, 0x1F568):
          copy_glyph(clocks, codepoint, cell * 2)

      target.generate(output_path)
      display_style = "Bold Italic" if style == "BoldItalic" else style
      target.familyname = "FantasqueSansM Terminal Nerd Font Mono"
      target.fontname = "FantasqueSansMTerminalNFM-" + style
      target.fullname = "FantasqueSansM Terminal Nerd Font Mono " + display_style
      target.generate(windows_path)
      target.close()
      symbols.close()
      clocks.close()
      ' \
                ${fantasque}/share/fonts/truetype/NerdFonts/FantasqueSansM/FantasqueSansMNerdFontMono-"$style".ttf \
                ${caskaydia}/share/fonts/truetype/NerdFonts/CaskaydiaMono/CaskaydiaMonoNerdFontMono-"$caskStyle".ttf \
                "$cozetteFile" \
                "$outDir/FantasqueSansMNerdFontMono-$style.ttf" \
                "$windowsDir/FantasqueSansMTerminalNerdFontMono-$style.ttf" \
                "$style"
            done

            runHook postInstall
    '';

    meta = fantasque.meta // {
      description = "Fantasque Sans Mono Nerd Font with terminal-safe Unicode symbols";
    };
  };
}
