# Managed-policy Google Chrome for kid accounts (and any host that
# imports it).
#
# WHY: Family Link supervision requires a signed-in Google account.
# The vanilla nixpkgs `chromium` build can't complete the
# `BrowserSignin: 2` flow because it lacks Google's OAuth API keys
# (the sign-in handshake redirects to a 404 on accounts.google.com).
# `pkgs.google-chrome` ships those keys baked in, so sign-in works.
#
# SCOPE on Linux: Chrome reads managed policies from the system-wide
# path `/etc/opt/chrome/policies/managed/*.json`. There is NO per-
# user policy mechanism — unlike Windows (HKCU vs HKLM) or macOS
# (~/Library/Preferences plists). Any user on the host who launches
# Chrome sees the same policy file. On pb-t480 this means the
# Family-Link gates (BrowserSignin, RestrictSigninToPattern,
# IncognitoModeAvailability, DeveloperToolsAvailability,
# ForceGoogleSafeSearch, etc.) apply to every Chrome user including
# the admin account p. p has accepted that trade-off — it's the
# price of Family Link working at all on Linux.
#
# This module is cross-class:
#   - homeManager.chrome-managed: a no-op placeholder. We don't
#     install google-chrome from here because (a) p's `chrome`
#     module already does and (b) HM would warn about duplicate
#     home.packages entries. Hosts that want kids to get chrome
#     just add both `chrome` and `chrome-managed` to the kid bundle.
#   - nixos.chrome-managed: drops the policy JSON at
#     /etc/opt/chrome/policies/managed/family-safety.json. Imported
#     by hosts that have any kid account.
#
# The actual policy content lives in the host's own asset directory
# (e.g. hosts/pb-t480/chrome-policy.json), so the policy JSON is
# treated as host-specific data, not module logic. Different hosts
# could ship different policy files by setting
# `chrome-managed.policyFile` differently.
#
# Pattern A: importing IS enabling. There is no enable flag.
#
# Retire when: Linux Chrome gains per-user managed-policy paths
# (long-shot — not on the upstream roadmap as of 2026), or kid
# accounts age out and the host stops importing this module.
{ lib, config, ... }:
let
  cfg = config.chrome-managed;
in
{
  options.chrome-managed = {
    policyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "../../hosts/pb-t480/chrome-policy.json";
      description = ''
        Path to the JSON file that will be installed at
        `/etc/opt/chrome/policies/managed/family-safety.json`.
        Required for the NixOS class to do anything; without it the
        module installs no policy file (Chrome runs unmanaged).
      '';
    };
  };

  # HM side: deliberately empty. Chrome itself is installed by the
  # `chrome` module (flake-modules/chrome.nix); both p's adult
  # bundle and the kid bundle import it. Keeping the install in one
  # place avoids HM's duplicate-home.packages warning.
  config.flake.modules.homeManager.chrome-managed = { ... }: { };

  config.flake.modules.nixos.chrome-managed = { ... }: {
    # Drop the policy JSON at the path Chrome scans on Linux.
    # `mkIf` so hosts that import the module without setting
    # policyFile don't crash with a path-coerce error.
    environment.etc = lib.mkIf (cfg.policyFile != null) {
      "opt/chrome/policies/managed/family-safety.json".source = cfg.policyFile;
    };
  };
}
