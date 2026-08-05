# mermaid-ascii — render Mermaid diagrams as text, for terminal viewing.
#
# WHY THIS EXISTS
# ---------------
# Not in nixpkgs (checked 2026-08-04: `nixpkgs#mermaid-ascii` does not
# resolve), and it is the only sensible way to show a ```mermaid block
# in `md-view` (flake-modules/markdown-viewer.nix).
#
# The obvious alternative, `mermaid-cli` (mmdc), IS in nixpkgs but drags
# in a full Chromium: measured 2.1 GiB closure. It also only emits
# PNG/SVG, which alacritty cannot display — mainline alacritty (0.17
# here) implements no image protocol, neither sixel nor the kitty
# graphics protocol — so the image would then need chafa (another
# 157 MiB) to become illegible Unicode-block art. Roughly 2.3 GiB on
# every host to render diagrams badly.
#
# mermaid-ascii is a single small Go binary emitting plain text, which
# is exactly what a pager wants. Actively maintained (1.4.0, Jul 2026),
# MIT licensed. It covers flowcharts and sequence diagrams; class and
# state diagrams are not supported upstream yet, and md-view leaves
# those blocks as source rather than pretending.
#
# RETIRE WHEN
# -----------
# nixpkgs packages mermaid-ascii (then delete this file and drop the
# entry from overlays/default.nix — the attribute name matches, so
# nothing else needs to change), OR md-view stops rendering mermaid,
# OR upstream goes unmaintained and the diagrams stop rendering
# correctly.
final: prev: {
  mermaid-ascii = prev.buildGoModule rec {
    pname = "mermaid-ascii";
    version = "1.4.0";

    src = prev.fetchFromGitHub {
      owner = "AlexanderGrooff";
      repo = "mermaid-ascii";
      rev = version;
      hash = "sha256-BAO0WnKbkHTkoZRZFtPuMiJvOcfBndeoShEym1QrFzs=";
    };

    vendorHash = "sha256-aB9sbTtlHbptM2995jizGFtSmEIg3i8zWkXz1zzbIek=";

    # Upstream ships a web-service subcommand whose tests want to bind a
    # port; nothing here uses it and the sandbox has no network.
    doCheck = false;

    ldflags = [ "-s" "-w" ];

    meta = with prev.lib; {
      description = "Render Mermaid diagrams as ASCII art";
      homepage = "https://github.com/AlexanderGrooff/mermaid-ascii";
      license = licenses.mit;
      mainProgram = "mermaid-ascii";
      platforms = platforms.unix ++ platforms.windows;
    };
  };
}
