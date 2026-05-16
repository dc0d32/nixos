// Helpers to read EGGHEAD_* env vars with the same set-vs-empty
// semantics the bash wizard uses (see `ask`/`ask_yesno` in
// scripts/egghead.sh: `${!name+x}` distinguishes a deliberately-empty
// override from an unset one — matters for EGGHEAD_EXTRA_USERS="").

export const ENV_PREFIX = "EGGHEAD_";

/**
 * Returns the env var value if SET (even if empty string), else
 * undefined. Mirrors bash `${!name+x}` logic.
 */
export function envGet(name: string): string | undefined {
  const full = ENV_PREFIX + name;
  return Object.prototype.hasOwnProperty.call(process.env, full)
    ? process.env[full] ?? ""
    : undefined;
}

/**
 * Like envGet but returns the supplied default if the env var is unset.
 * A set-but-empty env var wins over the default (deliberate "no value").
 */
export function envOr(name: string, fallback: string): string {
  const v = envGet(name);
  return v === undefined ? fallback : v;
}

/**
 * Default stateVersion: read EGGHEAD_DEFAULT_STATE_VERSION first
 * (egghead.nix injects this from `pkgs.lib.trivial.release`), else
 * fall back to a hard-coded recent stable so the TUI still launches
 * outside the Nix wrapper.
 */
export function defaultStateVersion(): string {
  return process.env.EGGHEAD_DEFAULT_STATE_VERSION ?? "25.05";
}
