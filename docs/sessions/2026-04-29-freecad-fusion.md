# 2026-04-29 — FreeCAD: Fusion-360-flavored defaults + addons

## Goal

Make FreeCAD 1.1.0 feel like Fusion 360 for a user migrating from
Fusion. Specifically:

1. **Mouse navigation** matching Fusion (MMB pan, Shift+MMB orbit,
   wheel zoom, LMB select).
2. **Dark theme** matching the rest of the desktop.
3. **Default workbench** = Part Design; default units = mm.
4. **Keyboard shortcuts** mapped onto Fusion intents (S=Sketch,
   E=Extrude, etc.).
5. **Toponaming-aware** defaults (1.0+ algorithm).
6. **GPU acceleration** sanity-checked (MSAA on, no software fallback).
7. **Useful addons pre-installed**: Assembly4, Fasteners, Sheet Metal,
   Defeaturing.

## Context

FreeCAD was already installed via
`modules/home/tools/hardware-hacking.nix` but unconfigured. The
existing user.cfg from a previous launch is left alone — we only
manage the keys we care about.

User decisions:

- **Config strategy**: startup macro that idempotently sets prefs each
  launch (rather than a fully-managed user.cfg, which would clobber
  FreeCAD's UI state writes). Lets the user override anything we
  don't manage from Tools → Edit Parameters.
- **Addon strategy**: each addon wrapped as a Nix derivation
  (`fetchFromGitHub` / `fetchgit`) and symlinked into
  `~/.local/share/FreeCAD/Mod/<name>`. Reproducible builds; the Addon
  Manager will refuse to upgrade externally-managed mods.
- **Addons**: Assembly4 (codeberg), Fasteners, Sheet Metal,
  Defeaturing. **TechDrawTools dropped** — does not exist as a
  separate addon; the wiki name refers to extensions now built into
  TechDraw in 1.x.

## Investigation

Spawned a research subagent against the FreeCAD 1.1.0 source tree
(commit `34a9716668b1ddeb55b914f1c5be644826bdbbbf`) to verify ParamGet
groups, key names, and value enums. Full report at
`/tmp/freecad-fusion-report.md` (not committed; this session log
captures the conclusions).

### Critical surprises

1. **No "run macro on startup" preference exists.** Grepped 1.1.0 for
   `RunOnStartup`, `MacroOnStart`, `StartupMacro`, `RunAtStartUp`,
   `AutoRunMacro`, `BootMacro` — zero hits. The *only* supported way
   to auto-run code at FreeCAD startup is to put `InitGui.py` in a
   directory under `~/.local/share/FreeCAD/Mod/<Name>/`. FreeCAD scans
   `Mod/` at startup and imports each subdir's init scripts
   (`App/FreeCADInit.py:103-160`). This is the right shape for Nix
   anyway: read-only directory, one file per language layer.

2. **Fusion-matching navigation is `Gui::RevitNavigationStyle`**, not
   the FreeCAD-default CADNavigationStyle and not InventorNavigationStyle.
   Verified by reading each style's `mouseButtons()`:
   - Revit: LMB select, MMB pan, **Shift+MMB orbit**, wheel zoom — exact Fusion match.
   - CAD: middle+left chord for orbit (not Fusion).
   - Inventor: Ctrl+LMB select (not Fusion).

3. **Shortcut group is `Shortcut`**, singular — `User
   parameter:BaseApp/Preferences/Shortcut`. Verified
   `Gui/ShortcutManager.cpp:40`. Easy to get wrong.

4. **AntiAliasing enum is non-sequential**: `0=None, 1=Line,
   2=2x, 3=4x, 4=8x, 5=6x` (yes, 4 = 8x). Verified
   `src/Gui/Multisample.h:44`. Pick `3` (MSAA4x) for the
   broadest-hardware sweet spot.

5. **Toponaming has no preference**. The new (1.0+) algorithm is the
   only naming engine in 1.x and is on by default
   (`Document::UseHasher = true`). Nothing to set; it Just Works.
   Future bumps shouldn't add a key here — there isn't one.

6. **TechDrawTools doesn't exist** as a third-party addon. The
   `TechDraw_Extension*` commands the user might've seen referenced
   are now built into TechDraw in 1.x. Dropped from the addon list.

## Implementation

### `modules/home/cad/freecad.nix` (new)

Gated on `variables.cad.freecad.enable`. Three concerns:

1. Installs `pkgs.freecad-wayland` (falls back to `pkgs.freecad` on
   nixpkgs revisions where -wayland isn't built).
2. Materializes four addons via `fetchFromGitHub` / `fetchgit`,
   pinned by commit hash. Bump procedure documented inline.
3. Builds a `FusionLike` mod via `runCommandLocal` from two source
   files (`Init.py`, `InitGui.py`) and symlinks all five mods into
   `~/.local/share/FreeCAD/Mod/<name>` via `xdg.dataFile`.

### `modules/home/cad/FusionLike/InitGui.py` (new)

Idempotent preference-setter. Re-runs every FreeCAD launch; touches
only the keys we care about. Documents the verified ParamGet groups,
keys, types, and source citations inline so future maintainers don't
have to re-derive them.

Sets:

- `View/NavigationStyle = Gui::RevitNavigationStyle` (Fusion mouse).
- `View/AntiAliasing = 3` (MSAA4x).
- `View/Gradient = false` + `BackgroundColor = #2D2D2DFF` (flat dark
  viewport).
- `MainWindow/StyleSheet = FreeCAD.qss` + `Theme = FreeCAD Dark`.
- `General/AutoloadModule = PartDesignWorkbench`.
- `OpenGL/UseSoftwareOpenGL = false` (defensive — default is already
  off).
- 17 keyboard shortcuts under `Shortcut/PartDesign_*`,
  `Shortcut/Sketcher_*`, `Shortcut/Std_*`.

### `modules/home/cad/FusionLike/Init.py` (new)

Tiny — only sets the units schema (mm), since this needs to apply
to non-GUI invocations of FreeCAD too (CLI scripts, FreeCADCmd).

### `modules/home/tools/hardware-hacking.nix`

Removed FreeCAD from this module — it now lives in
`modules/home/cad/freecad.nix` and shouldn't be coupled to the
hardware-hacking flag. KiCad stays since it's still EDA-flavored.

### `hosts/laptop/variables.nix`

Added `cad.freecad.enable = true`.

### `modules/home/default.nix`

Added `./cad/freecad.nix` to the desktop-only imports list.

## Verified

`nix build .#homeConfigurations."p@laptop".activationPackage` succeeds.
The activation package contains the expected layout under
`home-files/.local/share/FreeCAD/Mod/`:

```
Assembly4   -> /nix/store/...-Assembly4-623267b
Defeaturing -> /nix/store/...-source         (Defeaturing_WB)
FusionLike  -> /nix/store/...-freecad-fusionlike-mod
fasteners   -> /nix/store/...-source         (FreeCAD_FastenersWB)
sheetmetal  -> /nix/store/...-source         (FreeCAD_SheetMetal)
```

Not yet activated on the live system — user runs
`home-manager switch --flake .#"p@laptop"` to deploy.

## Files

New:
- `modules/home/cad/freecad.nix`
- `modules/home/cad/FusionLike/Init.py`
- `modules/home/cad/FusionLike/InitGui.py`

Modified:
- `hosts/laptop/variables.nix` — `cad.freecad.enable = true`.
- `modules/home/default.nix` — register `./cad/freecad.nix`.
- `modules/home/tools/hardware-hacking.nix` — drop freecad install
  (moved to the new module).

## Open / future

- **Addon version bumps**: addons aren't tag-stable; the inline
  `nix-prefetch-git` recipe documents the bump process. A future
  `flake.lock`-style file or `npins` setup would automate this.
- **Per-addon behavior tweaks**: e.g. Fasteners has its own pref
  group `Mod/Fasteners` we don't touch yet. Add to InitGui.py if
  needed.
- **Sketch-on-XY by default**: not a ParamGet key in 1.1.0; would
  require overriding `PartDesign_NewSketch`'s command implementation
  via a Python wrapper. Skipped — the Fusion-trained user will pick
  the plane in the workflow.
- **Move/Rotate of solids**: Fusion's "Modify → Move" doesn't have a
  direct PartDesign analogue (the existing `PartDesign_MoveFeature`
  is *tree* reordering, not geometric). For now we omit a binding;
  the user can use `Std_TransformManip` from the toolbar.
- **Nag about TechDrawTools**: if the user wanted TechDraw extensions
  specifically, they're already built in (1.x). No addon needed.

## Post-deploy follow-up: first-start wizard clobbers our writes

After the user deployed and launched FreeCAD once, three things were
broken:

1. The **first-start wizard** appeared (expected on a fresh user.cfg,
   but unwanted).
2. **NavigationStyle reverted** from `Gui::RevitNavigationStyle` (set
   by InitGui.py) back to `Gui::CADNavigationStyle`.
3. **Shortcut entries** were not visible in user.cfg, only the empty
   `Shortcut/Priorities` and `Shortcut/Settings` subgroups created by
   `ShortcutManager`'s constructor.

### Diagnosis

Read `src/Mod/Start/Gui/StartView.cpp`,
`src/Mod/Start/Gui/FirstStartWidget.cpp`, and
`src/Mod/Start/Gui/GeneralSettingsWidget.cpp` from the 1.1.0 tag.

The wizard's `GeneralSettingsWidget` builds three combo boxes
(Language, Unit System, Navigation Style) inside `retranslateUi()`.
Each combobox is wired to an `onXChanged(int)` slot that writes the
selected item's data back to ParamGet. Crucially, `addItem()` on an
empty `QComboBox` fires `currentIndexChanged(0)` *before*
`setCurrentIndex(<matching index>)` runs — so the first item added
gets written to user.cfg as a side-effect of populating the combo.

Sequence at first-launch:

1. `Init.py` sets `Units/UserSchema = 0`.
2. `InitGui.py` runs `_apply()` — writes NavigationStyle, theme,
   shortcuts, etc.
3. PartDesignWorkbench loads its commands.
4. The Start workbench activates → `StartView` constructor →
   `FirstStartWidget` → `GeneralSettingsWidget::retranslateUi()` →
   `addItem("English", "English")` fires
   `onLanguageChanged(0)` → write; same for unit system, then
   navigation style. Final NavigationStyle ends up as whatever the
   first item in `Gui::UserNavigationStyle::getUserFriendlyNames()`
   happens to be (alphabetical-by-Type-name).

The shortcut entries weren't actually missing — they were never
written, because `_apply()` ran fine but the **prior** launch (before
this fix was deployed) had no working InitGui.py. Verified by running
`exec(open('.../InitGui.py').read())` in `FreeCADCmd` — all 16 keys
landed in user.cfg correctly. So the script and the ParamGet path
were both fine; only the wizard interaction needed fixing.

### Fix

Suppress the wizard up-front in `Init.py` (which runs before any
workbench loads, including Start):

```python
start = App.ParamGet("User parameter:BaseApp/Preferences/Mod/Start")
start.SetBool("FirstStart2024", False)
start.SetBool("ShowOnStartup", False)
```

`FirstStart2024 = false` skips the wizard tab inside StartView (read
at `src/Mod/Start/Gui/StartView.cpp:165`).
`ShowOnStartup = false` skips the entire Start page on launch (read
at `src/Mod/Start/Gui/StartView.cpp:165`); user wanted PartDesign
loaded directly anyway.

With the wizard suppressed, the comboboxes never get a chance to
populate, so NavigationStyle and UserSchema stay where InitGui.py
set them.

### Files touched (follow-up)

- `modules/home/cad/FusionLike/Init.py` — added the two `Mod/Start`
  param writes with citations.
- `modules/home/cad/FusionLike/InitGui.py` — header comment expanded
  to explain the wizard interaction.
