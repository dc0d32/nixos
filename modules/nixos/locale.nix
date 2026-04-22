{ variables, ... }: {
  time.timeZone = variables.timezone;
  i18n.defaultLocale = variables.locale;
}
