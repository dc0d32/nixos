# Fantasque Sans Mono terminal face with grid-safe Unicode symbols.
#
# WHY THIS EXISTS
# Fantasque's Nerd Font Mono face deliberately keeps patched icons to one
# terminal cell, but omits Braille spinners, btop's filled triangles, and the
# Unicode clock faces. Core Text and DirectWrite then choose emoji or
# proportional fallback faces whose ink can spill into neighboring cells.
# Keep Fantasque's letterforms and existing Nerd glyphs, filling only those
# missing code points from monospace sources with explicit one- or two-cell
# advances. The Windows build additionally fills whole symbol blocks (arrows,
# math, technical, geometric, dingbats, ...) so no narrow symbol falls back.
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
  noto = "${prev.noto-fonts}/share/fonts/noto";
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
              case "$style" in
                Regular)    dejavuStyle=""; freeStyle="" ;;
                Bold)       dejavuStyle="-Bold"; freeStyle="Bold" ;;
                Italic)     dejavuStyle="-Oblique"; freeStyle="Oblique" ;;
                BoldItalic) dejavuStyle="-BoldOblique"; freeStyle="BoldOblique" ;;
              esac

              ${prev.fontforge}/bin/fontforge -lang=py -c '
      import fontforge
      import psMat
      import sys

      target_path, symbol_path, clock_path, output_path, windows_path, style = sys.argv[1:7]
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

      # Windows-only structural fill. Alacritty cannot configure a symbol
      # fallback and DirectWrite substitutes a proportional face for every
      # code point this font lacks, so any missing narrow glyph can spill over
      # neighbouring cells. Instead of patching glyphs one bug at a time,
      # cover whole Unicode blocks: every missing, narrow, non-emoji code
      # point that any monospace source has is copied in at exactly one cell,
      # trying sources in order of visual quality (monospace vector faces first,
      # then pixel-grid Unifont, then proportional Noto symbol/math/music faces
      # shrunk to fit and centred).
      # Left to the system on purpose: East-Asian-wide code points (CJK,
      # emoji), which belong at two cells in a colour or CJK face, and scripts
      # that need shaping or bidi (Arabic, Indic, Thai, ...), which no
      # monospace font can render correctly.
      # Linux and macOS outputs above are untouched.
      import unicodedata
      FILL_BLOCKS = [
          (0x00A0, 0x058F),    # Latin, IPA, Greek, Cyrillic, Armenian
          (0x10A0, 0x10FF),    # Georgian
          (0x1D00, 0x1FFF),    # phonetic ext, Latin ext additional, Greek ext
          (0x2000, 0x2BFF),    # punctuation .. arrows .. math .. technical .. dingbats
          (0x2C00, 0x2E7F),    # Glagolitic, Coptic, Tifinagh, supplemental punctuation
          (0xA640, 0xA7FF),    # Cyrillic ext B, modifier tone letters, Latin ext D
          (0xFB00, 0xFB06),    # Latin ligatures
          (0xFE50, 0xFE6F),    # small form variants
          (0xFFF0, 0xFFFD),    # specials
          (0x1D000, 0x1D3FF),  # musical and ancient symbols
          (0x1D400, 0x1D7FF),  # mathematical alphanumerics
          (0x1F000, 0x1FAFF),  # cards, enclosed, pictographs (narrow ones only)
          (0x1FB00, 0x1FBFF),  # legacy computing (sextants, ...)
      ]
      opened = [fontforge.open(path) for path in sys.argv[7:]]
      # (font, kind) in order of visual quality. mono: a monospace face whose
      # space width is its cell; grid: Unifont, 32 units per column, many
      # symbols drawn two columns wide; prop: proportional, fitted per glyph.
      fill_sources = [
          (symbols, "mono"),      # Caskaydia Mono Nerd Font
          (opened[0], "mono"),    # DejaVu Sans Mono
          (clocks, "mono"),       # Cozette
          (opened[1], "mono"),    # FreeMono
          (opened[2], "grid"),    # Unifont
          (opened[3], "prop"),    # Noto Sans Symbols
          (opened[4], "prop"),    # Noto Sans Symbols 2
          (opened[5], "prop"),    # Noto Sans Math
          (opened[6], "prop"),    # Noto Music
      ]

      def copy_fitted(source, kind, codepoint):
          em_scale = float(target.em) / source.em
          source[codepoint].unlinkRef()
          source.selection.select(codepoint)
          source.copy()
          target.selection.select(codepoint)
          target.paste()
          glyph = target[codepoint]
          src_width = source[codepoint].width
          src_cell = 32 if kind == "grid" else source[0x20].width
          if kind == "mono" and abs(src_width / float(src_cell) - 1) < 0.15:
              # Same one-column design as the face itself: match its stroke
              # weight by squeezing to exactly one cell.
              glyph.transform(psMat.scale(float(cell) / src_cell, em_scale))
          else:
              # Anything else keeps its aspect ratio, shrinks to fit one
              # cell if wider, and is centred.
              scale = em_scale * min(1.0, cell / (src_width * em_scale))
              glyph.transform(psMat.scale(scale, scale))
              glyph.transform(psMat.translate((cell - src_width * scale) / 2.0, 0))
          glyph.width = cell

      added = 0
      for lo, hi in FILL_BLOCKS:
          for codepoint in range(lo, hi + 1):
              if codepoint in target:
                  continue
              ch = chr(codepoint)
              if unicodedata.category(ch)[0] not in "LNPS" or unicodedata.east_asian_width(ch) in ("W", "F"):
                  continue
              for source, kind in fill_sources:
                  if codepoint not in source or source[codepoint].width <= 0:
                      continue
                  if kind in ("mono", "grid"):
                      src_cell = 32 if kind == "grid" else source[0x20].width
                      # Up to two columns wide; the transform shrinks it to fit.
                      if source[codepoint].width / float(src_cell) > 2.05:
                          continue
                  copy_fitted(source, kind, codepoint)
                  added += 1
                  break
      print("windows font: filled", added, "missing glyphs")
      for source in opened:
          source.close()

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
                "$style" \
                "${prev.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono$dejavuStyle.ttf" \
                "${prev.freefont_ttf}/share/fonts/truetype/FreeMono$freeStyle.ttf" \
                ${prev.unifont}/share/fonts/opentype/unifont.otf \
                ${noto}/NotoSansSymbols.ttf \
                ${noto}/NotoSansSymbols2-Regular.otf \
                ${noto}/NotoSansMath-Regular.otf \
                ${noto}/NotoMusic-Regular.otf
            done

            runHook postInstall
    '';

    meta = fantasque.meta // {
      description = "Fantasque Sans Mono Nerd Font with terminal-safe Unicode symbols";
    };
  };
}
