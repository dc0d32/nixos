# 2026-11-15 terminal font: full symbol fill on every platform

- Found on pb-mb that `~/Library/Fonts/HomeManager/` was missing, so macOS had
  no Fantasque at all. Home Manager only re-copies fonts when its marker file
  changes, so deleting the folder is not self-healing; re-run the same `rsync`
  (store `home-manager-fonts/share/fonts/` -> `~/Library/Fonts/HomeManager`).
- `overlays/fantasque-terminal.nix` now applies the whole-block Unicode fill
  (previously Windows-only) to the Linux/macOS face too. The two faces differ
  only in family name; cmap and advances are identical. Original glyphs are
  untouched (advance unchanged, bbox drift <= 1 unit from FontForge rounding).
- Cost: Regular face 2.56 MB -> 3.61 MB (about +4 MB across four styles).
  About 2.5% of the added glyphs (math alphanumerics, enclosed alphanumerics,
  legacy computing) draw slightly outside their cell; same as Windows before.
- FontForge output is captured and filtered: the known-benign messages
  (spline refigure, lost anchors, name/codepoint mismatch, ignored tables) are
  dropped, anything new still prints, and a failure dumps the whole log. Build
  log went from ~62,000 lines to 4.
- Trade-off accepted: narrow emoji-capable symbols (heart, check mark, sun)
  now always draw as monochrome text glyphs instead of falling back to the
  system emoji face.
