# SolveSpace — parametric 2D/3D CAD with a constraint solver (home-manager).
#
# Why it exists: the kids are learning geometry, and GeoGebra builds figures
# from constructions rather than from constraints. SolveSpace's sketch mode
# works like Fusion 360's: draw normal and construction lines, circles and
# arcs, pin them with dimensions and relations (parallel, perpendicular,
# equal, tangent, ...), and the solver moves the rest. It is small (a few
# hundred MiB) next to FreeCAD, runs offline, and also opens the same sketch
# as a 3D part when they are ready for that.
#
# It gives numbers, not symbolic formulas; the symbolic side is covered by
# GeoGebra Discovery under math.bitset.cc.
#
# Carried by the kid bundle only. Retire when: the kids stop using it, OR
# FreeCAD's Sketcher (flake.modules.homeManager.freecad) replaces it on
# every kid host.
{ ... }:
{
  flake.modules.homeManager.solvespace = { pkgs, ... }: {
    home.packages = [ pkgs.solvespace ];
  };
}
