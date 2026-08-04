# Electronics / robotics learning tools (home-manager).
#
# A beginner-friendly EDA + circuit-sim set for the mechatronics hobby:
#
#   * fritzing — drag-and-drop breadboard prototyping, Arduino-focused;
#     the gentle bridge from "wiring stuff up" to "designing a PCB".
#   * CircuitJS (Falstad) — animated analog circuit simulator, the best
#     tool for building gut-level intuition about voltage/current. It is
#     NOT packaged in our pinned stable nixpkgs (only `xcircuit` etc.),
#     and it is a pure-JS web app that runs offline once cached, so we
#     ship a desktop launcher that opens it as a standalone Chrome app
#     window instead of carrying an extra package.
#
# Heavier EDA (KiCad) and CAD (FreeCAD) live in their own modules; this
# is the "just getting started" tier. Carried by the desktop + kid HM
# bundles, so every graphical user on every graphical host gets it;
# headless (wsl, wsl-arm) and macOS (pb-mb) don't import those bundles.
#
# Retire when: nobody on the host is learning electronics, OR CircuitJS
#   lands in stable nixpkgs (then swap the launcher for the package).
{ ... }:
{
  flake.modules.homeManager.electronics = { pkgs, ... }:
    let
      circuitjs = pkgs.makeDesktopItem {
        name = "circuitjs";
        desktopName = "CircuitJS (Falstad)";
        comment = "Animated analog circuit simulator";
        categories = [ "Education" "Electronics" "Science" ];
        exec = "${pkgs.google-chrome}/bin/google-chrome-stable --app=https://www.falstad.com/circuit/circuitjs.html";
      };
    in
    {
      home.packages = [
        pkgs.fritzing
        circuitjs
      ];
    };
}
