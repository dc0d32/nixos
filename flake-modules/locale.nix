# System locale + timezone.
#
# Pattern A: hosts opt in by importing this module and setting the
# top-level options below. WSL hosts may skip this — the upstream WSL
# fork sets a default timezone of its own.
#
# mkDefault on both settings so WSL / hosts can override cleanly even
# when the option is set here.
{ lib, config, ... }:
let
  # Capture from outer flake-parts scope; the inner NixOS module's
  # `config` shadows this name.
  cfg = config.locale;
in
{
  options.locale = {
    timezone = lib.mkOption {
      type = lib.types.str;
      example = "America/Los_Angeles";
      description = "IANA tz database identifier (e.g. \"America/Los_Angeles\").";
    };
    lang = lib.mkOption {
      type = lib.types.str;
      example = "en_US.UTF-8";
      description = "System default locale (LANG / LC_ALL).";
    };
  };

  config.flake.modules.nixos.locale = { lib, ... }: {
    time.timeZone = lib.mkDefault cfg.timezone;
    i18n.defaultLocale = lib.mkDefault cfg.lang;
  };
}
