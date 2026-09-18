# 2026-09-08 - Terminal glyph overlap

## Problem

Fantasque Sans Mono Nerd Font stayed readable for normal text and private-use
  icons, but omitted several symbols used by terminal tools:

- btop's filled up/down triangles (`U+25B2`, `U+25BC`)
- Braille spinner frames (`U+2800`-`U+28FF`)
- clock-face spinner frames (`U+1F550`-`U+1F567`)

Windows Terminal and macOS Terminal therefore selected platform fallback
fonts. Those fallback glyphs did not reliably fit the terminal grid: arrows
and triangles could spill into the following cell, while emoji-style clock
faces could render wider than the two cells assigned by Unicode width.

## Decision

Keep Fantasque rather than changing the coding typeface. The
`fantasque-terminal` overlay derives a font from the existing Nerd Font Mono
faces and adds only the missing symbols:

- triangles and Braille come from Caskaydia Mono Nerd Font and are scaled to
exactly one Fantasque cell;
- clock faces come from Cozette and retain an explicit two-cell advance.

The Linux/macOS output preserves Fantasque's existing family, style, and
PostScript names. Existing Alacritty and Terminal.app profile selections
therefore adopt the fixed face without configuration changes.

Windows receives the same glyphs under the distinct family
`FantasqueSansM Terminal Nerd Font Mono`. This avoids trying to overwrite a
Scoop-owned font while Windows Terminal has it open. `hm_win` installs and
registers the four generated faces per-user under content-addressed filenames,
updates Windows Terminal to the new family, and retires the old Scoop font
package on the next `--setup`. Later revisions are installed beside any loaded
font files; the installer balances native font-resource references and removes
stale revisions only after asking Windows to unload them.

## Verification

- The macOS Home Manager activation package builds with all four patched
styles.
- Glyph inspection confirms one-cell advances for triangles and Braille,
two-cell advances and bounded outlines for clock faces, and unchanged
one-cell private-use tmux icons.
- The x86_64-linux Windows bundle and `p@wsl` Home Manager generation build
on Andromeda.
- The generated Windows bundle contains all four faces and selects the
distinct Windows family.
- Pure `nix flake check` passes.

## Deployment

- macOS/Linux: activate the normal Home Manager profile and restart terminal
applications so their font caches reopen the replaced face.
- Windows: run `hm_win --setup`, then restart Windows Terminal.
