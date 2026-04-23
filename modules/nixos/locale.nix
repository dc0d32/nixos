{ variables, lib, ... }: {
  # mkDefault so the upstream WSL fork (which sets a default timezone) and
  # hosts can override cleanly.
  time.timeZone = lib.mkDefault variables.timezone;
  i18n.defaultLocale = lib.mkDefault variables.locale;
}
