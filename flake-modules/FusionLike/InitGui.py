# FusionLike/InitGui.py — Fusion-360-flavored defaults for FreeCAD 1.1.0.
#
# Loaded automatically by FreeCAD: every directory under
# ~/.local/share/FreeCAD/Mod/ has its `Init.py` and `InitGui.py` imported
# at startup (App/FreeCADInit.py + Gui/FreeCADGuiInit.py). This is the
# only supported way to run code at FreeCAD startup — there is NO "macro
# on startup" preference in 1.1.0 (verified by grepping the 1.1.0 source
# for RunOnStartup, MacroOnStart, StartupMacro etc.; zero hits).
#
# Idempotency: every key we touch is overwritten on every launch. Keys
# we don't touch are preserved. The user can still override any of these
# from Tools → Edit Parameters between launches; our writes will reset
# them at next startup, so the source of truth lives here, in this file.
#
# IMPORTANT: this script runs DURING FreeCADGuiInit.InitApplications(),
# i.e. before workbenches activate and before the Start workbench shows
# its FirstStartWidget. The wizard's GeneralSettingsWidget would otherwise
# clobber our NavigationStyle / UserSchema writes when its comboboxes
# emit `currentIndexChanged` on populate. We suppress the wizard up-front
# in Init.py (FirstStart2024 = false), so by the time the user sees a
# window, the combos never get a chance to fire.
#
# All ParamGet groups, key names, and value enums are verified against
# FreeCAD 1.1.0 source (commit 34a9716668b1ddeb55b914f1c5be644826bdbbbf).
# See docs/sessions/2026-04-29-freecad-fusion.md for citations.

import FreeCAD as App


def _apply():
    P = App.ParamGet

    # ── 1. Navigation: Fusion-360 mouse mapping ─────────────────────────
    # Gui::RevitNavigationStyle is the only built-in style whose
    # mouseButtons() matches Fusion 360 exactly:
    #   LMB        = select
    #   MMB        = pan
    #   Shift+MMB  = orbit
    #   Wheel      = zoom
    # CADNavigationStyle (FreeCAD default) uses MMB+LMB chords for orbit,
    # which is *not* what Fusion users expect. Source:
    # src/Gui/Navigation/RevitNavigationStyle.cpp mouseButtons().
    view = P("User parameter:BaseApp/Preferences/View")
    view.SetString("NavigationStyle", "Gui::RevitNavigationStyle")
    view.SetBool("ZoomAtCursor", True)         # zoom toward mouse cursor
    view.SetFloat("ZoomStep", 0.2)             # smooth-ish wheel step
    view.SetInt("RotationMode", 1)             # orbit around point under cursor
    view.SetBool("ShowRotationCenter", True)   # visual feedback on orbit
    # InvertZoom: leave at FreeCAD default (true). FreeCAD's "true" means
    # "scroll-up zooms in", which matches Fusion. If you prefer the other
    # direction, set False here.

    # ── 2. Antialiasing & rendering ─────────────────────────────────────
    # AntiAliasing enum is non-sequential — verified in
    # src/Gui/Multisample.h:44. 0=None, 1=Line, 2=2x, 3=4x, 4=8x, 5=6x.
    # MSAA4x is the broadest hardware sweet spot.
    view.SetInt("AntiAliasing", 3)

    # ── 3. Dark theme ───────────────────────────────────────────────────
    # FreeCAD 1.1.0 ships exactly one stylesheet (FreeCAD.qss) and three
    # color themes (Classic, FreeCAD Light, FreeCAD Dark) under
    # src/Gui/Stylesheets/parameters/. The combination below gives a
    # dark UI close to Fusion 360's default.
    mw = P("User parameter:BaseApp/Preferences/MainWindow")
    mw.SetString("StyleSheet", "FreeCAD.qss")
    mw.SetString("Theme", "FreeCAD Dark")

    # 3D viewport: flat dark background instead of the default sky-blue
    # gradient. RGBA8 packed as uint32 in 0xRRGGBBAA order. 0x2D2D2DFF
    # = #2D2D2D opaque, the dark grey Fusion uses.
    view.SetBool("Gradient", False)
    view.SetBool("RadialGradient", False)
    view.SetUnsigned("BackgroundColor", 0x2D2D2DFF)

    # ── 4. Default workbench: Part Design ──────────────────────────────
    # Fusion's default workspace is its parametric solid modeller; in
    # FreeCAD that's PartDesign.
    P("User parameter:BaseApp/Preferences/General").SetString(
        "AutoloadModule", "PartDesignWorkbench"
    )

    # ── 5. GPU acceleration sanity check ────────────────────────────────
    # Make sure software rendering isn't on. (Default is false; we set
    # it explicitly so a previously-flipped value gets reverted.)
    P("User parameter:BaseApp/Preferences/OpenGL").SetBool(
        "UseSoftwareOpenGL", False
    )

    # ── 6. Fusion-style keyboard shortcuts ──────────────────────────────
    # Group is "Shortcut" (singular) — verified in Gui/ShortcutManager.cpp:40.
    # Each value is a String; multi-key sequences use ", " as separator
    # (e.g. "G, N"). Empty string clears.
    #
    # Where a Fusion shortcut already matches a FreeCAD default we still
    # write it explicitly so the binding can't drift if FreeCAD ever
    # changes its default.
    sc = P("User parameter:BaseApp/Preferences/Shortcut")
    shortcuts = {
        # PartDesign — solid features
        "PartDesign_NewSketch":        "S",          # Fusion: S = Sketch
        "PartDesign_Pad":              "E",          # Fusion: E = Extrude (additive)
        "PartDesign_Pocket":           "Shift+E",    # cut extrude
        "PartDesign_Hole":             "H",
        "PartDesign_Revolution":       "R",
        "PartDesign_Groove":           "Shift+R",
        "PartDesign_Fillet":           "F",
        "PartDesign_Chamfer":          "Shift+C",
        "PartDesign_Mirrored":         "Shift+M",
        "PartDesign_LinearPattern":    "Shift+L",
        "PartDesign_PolarPattern":     "Shift+P",
        "PartDesign_AdditiveLoft":     "L",
        "PartDesign_AdditivePipe":     "Shift+S",    # sweep
        "PartDesign_Body":             "B",          # new body / "component"

        # Sketcher
        "Sketcher_Move":               "M",
        "Sketcher_ToggleConstruction": "X",          # Fusion: X toggles construction

        # Std
        "Std_Measure":                 "I",          # Fusion: I = Inspect/Measure
    }
    for cmd, key in shortcuts.items():
        sc.SetString(cmd, key)


_apply()
