# zoom.nix — Zoom desktop client (home-manager).
#
# Why this module exists:
#   School/extracurriculars increasingly require Zoom and the Linux PWA
#   experience is poor (no virtual-background, breakout rooms flaky,
#   audio device routing limited). Packaging the native client as a
#   tiny dendritic HM module lets any host opt in by importing
#   `config.flake.modules.homeManager.zoom` — currently the family-laptop
#   kid accounts (m, s) — without dragging it into pb-x1's closure.
#
# Why HM (not NixOS):
#   Zoom has no system-level integration (no daemon, no udev, no
#   firewall hole punching). It's purely a per-user GUI app, so
#   home.packages is the right deployment surface.
#
# Retire when:
#   - Every consumer migrates to the Zoom PWA / web client and the
#     native binary is no longer wanted, OR
#   - Zoom ships an official Flatpak/AppImage that we'd rather use.
{
  flake.modules.homeManager.zoom = { pkgs, ... }: {
    home.packages = [ pkgs.zoom-us ];
  };
}
