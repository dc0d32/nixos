# Managed-policy chromium for kid accounts.
#
# WHY: On Linux, Chrome and Chromium both read managed-policy JSON
# from system-wide paths (Chrome: /etc/opt/chrome/policies/managed/,
# Chromium: /etc/chromium/policies/managed/). There is no per-user
# policy override mechanism on Linux — unlike Windows (HKCU vs
# HKLM) or macOS (~/Library/Preferences plists). To get per-user
# enforcement, we install DIFFERENT browser packages for different
# users: chromium for the kids (this module), google-chrome for the
# parent (flake-modules/chrome.nix). Each binary reads from its
# own /etc/ subtree, so the policies effectively scope to "anyone
# who launches chromium on this box" — in practice, the kids.
#
# This module is cross-class:
#   - homeManager.chromium-managed: install pkgs.chromium and the
#     chromium-flags.conf wrapper config in the user's ~/.config/.
#     Importing kids opt in by importing this in their HM module.
#   - nixos.chromium-managed: declares the
#     /etc/chromium/policies/managed/family-safety.json policy file.
#     Imported by hosts that have any kid account using chromium.
#
# Kids' HM module imports `chromium-managed` instead of `chrome`.
# The parent (`p`) keeps importing `chrome` and is unaffected.
#
# The actual policy content lives in the host's own asset directory
# (e.g. hosts/family-laptop/chromium-policy.json), so the policy
# JSON is treated as host-specific data, not module logic. Different
# hosts could ship different policy files by setting
# `chromium-managed.policyFile` differently.
#
# Pattern A: importing IS enabling. There is no enable flag.
#
# Retire when: Linux Chromium gains per-user managed-policy paths
# (long-shot — not on the upstream roadmap as of 2026), or kid
# accounts age out and the host stops importing this module.
{ lib, config, ... }:
let
  cfg = config.chromium-managed;
in
{
  options.chromium-managed = {
    policyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "../../hosts/family-laptop/chromium-policy.json";
      description = ''
        Path to the JSON file that will be installed at
        `/etc/chromium/policies/managed/family-safety.json`. Required
        for the NixOS class to do anything; without it the module
        installs no policy file (chromium runs unmanaged).
      '';
    };
  };

  config.flake.modules.homeManager.chromium-managed = { pkgs, ... }: {
    home.packages = [ pkgs.chromium ];

    # Wayland + dark-mode flags, mirrors flake-modules/chrome.nix so
    # kid chromium feels the same as parent chrome on this box.
    home.sessionVariables = {
      NIXOS_OZONE_WL = "1";
      GTK_USE_PORTAL = "1";
    };

    # nixpkgs' chromium wrapper reads ~/.config/chromium-flags.conf
    # at launch and appends each line as a CLI flag.
    xdg.configFile."chromium-flags.conf".text = ''
      --disable-features=WaylandWindowDecorations
      --enable-features=WebUIDarkMode
      --force-dark-mode
    '';
  };

  config.flake.modules.nixos.chromium-managed = { ... }: {
    # Drop the policy JSON at the path Chromium scans on Linux.
    # `mkIf` so hosts that import the module without setting
    # policyFile don't crash with a path-coerce error.
    environment.etc = lib.mkIf (cfg.policyFile != null) {
      "chromium/policies/managed/family-safety.json".source = cfg.policyFile;
    };
  };
}
