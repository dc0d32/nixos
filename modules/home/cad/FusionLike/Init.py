# FusionLike/Init.py
#
# Runs in both GUI and non-GUI (cli) FreeCAD startup. We keep this file
# small and reserve UI/Qt mutations for InitGui.py — Init.py executes
# before the Gui module has been imported, and many `ParamGet` keys
# under `Preferences/MainWindow` only take effect after the GUI starts.
#
# The only thing we set here is the units schema, which is consulted by
# both gui and headless paths.
import FreeCAD as App

# Standard (mm/kg/s/°). Schema integer values verified against
# FreeCAD 1.1.0 src/Base/UnitsSchemasData.h:
#   0 Internal (mm/kg/s/°)   <-- this one
#   1 MKS, 2 Imperial, 3 ImperialDecimal, 4 Centimeter,
#   5 ImperialBuilding, 6 MmMin, 7 ImperialCivil, 8 FEM, 9 MeterDecimal
App.ParamGet("User parameter:BaseApp/Preferences/Units").SetInt("UserSchema", 0)

# ── Suppress the first-start wizard ────────────────────────────────────
# FreeCAD 1.1.0 ships a "first start" wizard (StartGui::FirstStartWidget)
# that pops up the very first time you launch FreeCAD. The wizard's
# GeneralSettingsWidget contains comboboxes for language, unit system, and
# navigation style; when the comboboxes are populated, their
# `currentIndexChanged` signals fire and OVERWRITE the values we set in
# InitGui.py — including NavigationStyle, which silently reverts from
# Revit (Fusion-style) to whatever the first item in the combo is.
#
# The only safe fix is to suppress the wizard before it ever shows. The
# StartView constructor reads `Mod/Start/FirstStart2024` (default true)
# to decide whether to show the wizard tab; we set it to false here, in
# Init.py, which runs before any workbench (including Start) loads.
#
# We also set `ShowOnStartup = false` because the user has PartDesign as
# default workbench and doesn't need the recent-files Start page either.
# Source: src/Mod/Start/Gui/StartView.cpp lines 78, 165, 367.
start = App.ParamGet("User parameter:BaseApp/Preferences/Mod/Start")
start.SetBool("FirstStart2024", False)
start.SetBool("ShowOnStartup", False)
