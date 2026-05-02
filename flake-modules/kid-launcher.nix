# Kid launcher hygiene — hide app-menu entries that shouldn't be
# user-facing on the kid accounts (m, s on pb-t480).
#
# The kid HM bundle imports a bunch of modules whose closures drop
# `.desktop` entries the kids never need to launch directly:
# theming control panels (qt5ct/qt6ct), audio control surfaces
# (easyeffects/calf/pwvucontrol), CLI tools that auto-register
# launchers (btop/htop/yazi), screenshot annotators invoked from
# compositor hotkeys (satty), Thunar settings/helper entries, the
# duplicate Chrome launcher, and the wlroots quickshell internal
# entry. Hiding them is purely a UX decision: the binaries stay
# installed and continue to work when invoked by code paths that
# need them (quickshell hotkeys, Thunar context menus, etc.).
#
# We use `xdg.desktopEntries.<id> = { name; noDisplay = true; }`
# rather than dropping the packages, because most of these come in
# through transitive deps of features we DO want (audio suite,
# Thunar, blueman, Chrome). HM's xdg.desktopEntries writes a
# higher-priority `~/.config/...` entry that shadows the system one
# when XDG_DATA_DIRS is walked.
#
# `name` is required by HM's option type (it's mandatory in the
# spec); the value is irrelevant once `noDisplay = true`. Using the
# id string for readability.
#
# Pattern A enable: import this module from the kid bundle (already
# done in flake-modules/bundles/home-kid.nix). Adult HM configs
# don't import it and see the full app menu.
#
# Retire when: any of these underlying packages drop the
# .desktop entry upstream (then remove that line), OR the kid
# accounts are merged with the adult `desktop` bundle (delete the
# whole module).
{
  flake.modules.homeManager.kid-launcher = { lib, ... }:
    let
      hide = id: {
        name = id;
        noDisplay = true;
      };
      hidden = [
        # Bluetooth — keep blueman-manager visible (the actual UI
        # for pairing). blueman-adapters is a control panel for
        # adapter properties that's polkit-gated and useless to
        # kids.
        "blueman-adapters"

        # CLI process viewers that auto-install launchers.
        "btop"
        "htop"

        # Audio control surfaces. Pulled in by the audio module
        # (easyeffects pulls calf as a dependency for its plugin
        # set). Kids shouldn't be poking the EQ.
        "calf"
        "com.github.wwmm.easyeffects"
        "com.saivert.pwvucontrol"

        # Duplicate Chrome launcher — google-chrome.desktop is the
        # one that actually opens.
        "com.google.Chrome"

        # imv is fine, but the directory-mode variant is a power-
        # user thing kids won't use.
        "imv-dir"

        # Compositor service launcher — not user-facing.
        "org.quickshell"

        # Qt theming control panels.
        "qt5ct"
        "qt6ct"

        # Screenshot annotator, invoked from quickshell hotkey.
        "satty"

        # Thunar helper / settings entries; the main "thunar"
        # launcher stays visible.
        "thunar-bulk-rename"
        "thunar-settings"
        "thunar-volman-settings"

        # mpv multi-instance helper script.
        "umpv"

        # Archive manager invoked from Thunar's context menu;
        # standalone launcher is noise.
        "xarchiver"

        # Terminal file manager — kids use the thunar GUI.
        "yazi"
      ];
    in
    {
      xdg.desktopEntries = lib.genAttrs hidden hide;
    };
}
