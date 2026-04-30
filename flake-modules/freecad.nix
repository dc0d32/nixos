# FreeCAD with a "feels like Fusion 360" preference pack, a few staple
# addons, and a Wayland-native binary.
#
# Migrated from modules/home/cad/freecad.nix. Pattern A: importing this
# module IS enabling it (legacy `cad.freecad.enable` gate dropped).
#
# Why the gymnastics
# ------------------
# FreeCAD persists user preferences in a runtime-mutable XML file
# (~/.config/FreeCAD/v1-1/user.cfg) that the app rewrites on every quit.
# Symlinking it from the Nix store would prevent FreeCAD from saving any
# UI state (recent files, window geometry, last opened workbench, …).
#
# FreeCAD has no built-in "run macro on startup" preference (verified
# against 1.1.0 source — see docs/sessions/2026-04-29-freecad-fusion.md).
# The only supported way to auto-execute Python code at startup is to
# place an `InitGui.py` (and optionally `Init.py`) inside a directory
# under ~/.local/share/FreeCAD/Mod/<Name>/. FreeCAD scans that dir at
# startup (App/FreeCADInit.py) and imports each Mod's init script.
#
# So: we ship a `FusionLike` "addon" containing only an InitGui.py that
# calls App.ParamGet(...).SetX(...) for every key we care about, every
# launch, idempotently. FreeCAD's own writes are never fought because
# we touch only the keys we've opted into. Anything the user changes in
# Tools → Edit Parameters that we don't manage is preserved across
# launches.
#
# The third-party addons (Assembly4, Fasteners, SheetMetal, Defeaturing)
# are pure-Python; we point xdg.dataFile.<dir>.source at fetched store
# paths so each addon dir is a read-only symlink. The Addon Manager will
# notice they're "managed externally" and refuse to upgrade them, which
# is what we want from a reproducible build.
#
# Retire when: FreeCAD is no longer used or the FusionLike preference
# pack moves into upstream/an addon manifest.
{
  flake.modules.homeManager.freecad = { pkgs, ... }: let
    # Pinned addon revs. Bump in lockstep when something breaks.
    # Each `src` is a read-only directory; FreeCAD symlinks-in are fine
    # because addons are pure Python read at import time.
    #
    # Revs are tip-of-default-branch as of the date below; most of these
    # repos don't tag releases with any cadence, so pinning to commit
    # hash is the only reliable knob. Bump by re-running:
    #   nix shell nixpkgs#nix-prefetch-git --command nix-prefetch-git \
    #     --no-deepClone <url>
    # Last bump: 2026-04-29.
    assembly4 = pkgs.fetchgit {
      # Codeberg, not GitHub — Zolko moved off GitHub in 2024.
      url = "https://codeberg.org/Zolko/Assembly4.git";
      rev = "623267bdbe1fb0ed41a9d4ffb50515ed260b8ac4";
      hash = "sha256-nIYIbDxHvouvDonvI9WQA8Yf9HYo8adzhEf6P5L/bpY=";
    };
    fasteners = pkgs.fetchFromGitHub {
      owner = "shaise";
      repo = "FreeCAD_FastenersWB";
      rev = "5ff8137bb03b4bd8ea3141e12a4268033d2d399c";
      hash = "sha256-+8xib1NQ0MYcyzyvOYIDu0p5vbWPpfYwlqGnUjUj4WA=";
    };
    sheetmetal = pkgs.fetchFromGitHub {
      owner = "shaise";
      repo = "FreeCAD_SheetMetal";
      rev = "138709cca64ab5ecb62d3e2cbbc6786ee07a2e4f";
      hash = "sha256-U+QlSXkkKcaGAkoHo0IrldRUzv4kY51gVKRcnqC1kbI=";
    };
    defeaturing = pkgs.fetchFromGitHub {
      owner = "easyw";
      repo = "Defeaturing_WB";
      rev = "95ca1111f3b24a8e0f3ab33e51adf68a94b5cdec";
      hash = "sha256-5FQ7LI3GrNjQ5gopFtE10QJYy4powfwDzZmeYHTQNmk=";
    };

    # The FusionLike auto-startup mod. Two files:
    #   Init.py    — runs in non-GUI (cli) mode too. We use it only to set
    #                preferences that don't depend on Gui being loaded.
    #   InitGui.py — runs once per GUI session, after Gui module exists but
    #                before any workbench is activated. Safe place to call
    #                ParamGet().SetX() for every Fusion-like default.
    fusionLikeMod = pkgs.runCommandLocal "freecad-fusionlike-mod" { } ''
      mkdir -p $out
      cp ${./FusionLike/Init.py} $out/Init.py
      cp ${./FusionLike/InitGui.py} $out/InitGui.py
    '';
  in {
    home.packages = [
      # Native Wayland binary; falls back to xwayland-flavored freecad on
      # nixpkgs revisions where -wayland isn't built.
      (pkgs.freecad-wayland or pkgs.freecad)
    ];

    # Each Mod is a read-only symlink into ~/.local/share/FreeCAD/Mod/<dir>.
    # FreeCAD scans this directory at startup and imports each subdir's
    # InitGui.py. Names matter: each must be a valid Python identifier (no
    # dashes); FreeCAD treats the dir name as the module name.
    xdg.dataFile = {
      "FreeCAD/Mod/FusionLike".source = fusionLikeMod;
      "FreeCAD/Mod/Assembly4".source = assembly4;
      "FreeCAD/Mod/fasteners".source = fasteners;
      "FreeCAD/Mod/sheetmetal".source = sheetmetal;
      "FreeCAD/Mod/Defeaturing".source = defeaturing;
    };
  };
}
