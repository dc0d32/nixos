// Wizard answers + step definitions. Each step is one screen in the
// TUI. The order here matches scripts/egghead.sh main(); any new
// question added there must also appear here so the TUI keeps
// prompting for it.
//
// "kind" determines which Ink primitive renders the step:
//   - "text"     → ink-text-input
//   - "choice"   → ink-select-input
//   - "yesno"    → ink-select-input over ["yes","no"]
//   - "multi"    → custom checklist (features only)
//   - "password" → ink-text-input with mask="*" (passwords)
//   - "extras"   → multi-user sub-wizard (extras only)
//
// "defaultFrom" is a function so role-dependent defaults are evaluated
// lazily (after the role is picked).
import { envOr, defaultStateVersion } from "./env.js";
import { Role, roleByName } from "./roles.js";

export interface ExtraUser {
  login: string;
  fullname: string;
  profile: string;
  password: string;
}

export interface Answers {
  HOSTNAME: string;
  ROLE: string;
  DISK: string;
  PRIMARY_USER: string;
  PRIMARY_FULLNAME: string;
  PRIMARY_HM: string;
  PRIMARY_PASSWORD: string;
  // JSON-encoded array of {login, fullname, profile, password}.
  // bash side hashes plain passwords via mkpasswd before emitting.
  EXTRA_USERS_JSON: string;
  FEATURES: string;
  GPU_DRIVER: string;
  TZ: string;
  LOCALE: string;
  KEYMAP: string;
  STATE_VERSION: string;
  LUKS: string;
  ROOT_PASSWORD: string;
  UNATTENDED: string;
}

export type StepKind =
  | "text"
  | "choice"
  | "yesno"
  | "multi"
  | "password"
  | "extras";

export interface StepDef {
  key: keyof Answers;
  kind: StepKind;
  prompt: string;
  help?: string;
  choices?: string[];
  // Default depends on prior answers (mainly the picked role).
  defaultFrom: (prior: Partial<Answers>) => string;
  // Per-step validator. Return undefined for ok, or an error message.
  validate?: (value: string, prior: Partial<Answers>) => string | undefined;
  // If false, skip this step entirely given the prior answers.
  shouldRun?: (prior: Partial<Answers>) => boolean;
  // Hide the value in the sidebar (for passwords). Sidebar will show
  // "(set)" / "(unset)" instead.
  secret?: boolean;
}

const HOSTNAME_RE = /^[a-z][a-z0-9-]*$/;
const USERNAME_RE = /^[a-z_][a-z0-9_-]*$/;

const role = (prior: Partial<Answers>): Role | undefined =>
  prior.ROLE ? roleByName(prior.ROLE) : undefined;

export const STEPS: StepDef[] = [
  {
    key: "HOSTNAME",
    kind: "text",
    prompt: "hostname",
    help: "DNS-ish name, [a-z][a-z0-9-]*. Used as the flake config key.",
    defaultFrom: () => envOr("HOSTNAME", ""),
    validate: (v) =>
      HOSTNAME_RE.test(v)
        ? undefined
        : "must match [a-z][a-z0-9-]* (lowercase, start with letter)",
  },
  {
    key: "ROLE",
    kind: "choice",
    prompt: "role template",
    help: "Pre-canned feature sets. Per-role defaults pre-fill later prompts.",
    choices: [
      "bare-metal-laptop",
      "bare-metal-desktop",
      "vm-headless",
      "vm-desktop",
    ],
    defaultFrom: () => envOr("ROLE", "bare-metal-laptop"),
  },
  {
    key: "DISK",
    kind: "text",
    prompt: "target disk (WILL BE WIPED)",
    help: "Whole-disk path, e.g. /dev/nvme0n1 or /dev/sda.",
    defaultFrom: (p) => envOr("DISK", role(p)?.disk ?? "/dev/sda"),
    validate: (v) =>
      v.startsWith("/dev/") ? undefined : "must start with /dev/",
  },
  {
    key: "PRIMARY_USER",
    kind: "text",
    prompt: "primary user login",
    defaultFrom: () => envOr("PRIMARY_USER", "p"),
    validate: (v) =>
      USERNAME_RE.test(v) ? undefined : "must match [a-z_][a-z0-9_-]*",
  },
  {
    key: "PRIMARY_FULLNAME",
    kind: "text",
    prompt: "primary user full name",
    defaultFrom: (p) => envOr("PRIMARY_FULLNAME", p.PRIMARY_USER ?? "p"),
  },
  {
    key: "PRIMARY_HM",
    kind: "choice",
    prompt: "primary HM profile",
    choices: ["base", "dev", "desktop", "kid"],
    defaultFrom: (p) => envOr("PRIMARY_HM", role(p)?.hm ?? "desktop"),
  },
  {
    key: "PRIMARY_PASSWORD",
    kind: "password",
    prompt: "primary user password",
    help: "Hashed (yescrypt) before commit. Empty = no login (set later via `sudo passwd`).",
    defaultFrom: () => envOr("PRIMARY_PASSWORD", ""),
    secret: true,
  },
  {
    key: "EXTRA_USERS_JSON",
    kind: "extras",
    prompt: "additional users",
    help: "Optional: kids, a second admin, etc. Each gets a home dir + HM bundle. Enter loops 'add another?' until you stop.",
    defaultFrom: () => envOr("EXTRA_USERS_JSON", "[]"),
  },
  {
    key: "FEATURES",
    kind: "multi",
    prompt: "feature toggles",
    help: "checkboxes; pre-checked from the role's defaults. Anything you toggle here flows into the bridge's imports list.",
    defaultFrom: (p) => envOr("FEATURES", role(p)?.features ?? ""),
  },
  {
    key: "GPU_DRIVER",
    kind: "choice",
    prompt: "gpu driver",
    choices: ["intel", "amd", "nvidia", "none"],
    defaultFrom: () => envOr("GPU_DRIVER", "intel"),
    shouldRun: (p) => ` ${p.FEATURES ?? ""} `.includes(" gpu "),
  },
  {
    key: "TZ",
    kind: "text",
    prompt: "timezone",
    defaultFrom: () => envOr("TZ", "America/Los_Angeles"),
  },
  {
    key: "LOCALE",
    kind: "text",
    prompt: "locale",
    defaultFrom: () => envOr("LOCALE", "en_US.UTF-8"),
  },
  {
    key: "KEYMAP",
    kind: "text",
    prompt: "console keymap",
    defaultFrom: () => envOr("KEYMAP", "us"),
  },
  {
    key: "STATE_VERSION",
    kind: "text",
    prompt: "system.stateVersion",
    defaultFrom: () => envOr("STATE_VERSION", defaultStateVersion()),
  },
  {
    key: "LUKS",
    kind: "yesno",
    prompt: "encrypt root partition with LUKS?",
    help: "Passphrase prompt at install + every boot. No TPM unlock in v1.",
    defaultFrom: () => envOr("LUKS", "no"),
  },
  {
    key: "ROOT_PASSWORD",
    kind: "password",
    prompt: "root recovery password",
    help: "Hashed before commit. Console + SSH recovery if X breaks. Default 'recovery' is fine for a freshly-installed host; rotate on first boot. Empty = no root login.",
    defaultFrom: () => envOr("ROOT_PASSWORD", "recovery"),
    secret: true,
  },
  {
    key: "UNATTENDED",
    kind: "yesno",
    prompt: "unattended host?",
    help: "Adds auto-upgrade + nixos-clone + hm-auto-upgrade.",
    defaultFrom: (p) => envOr("UNATTENDED", role(p)?.unattended ?? "no"),
  },
];

/**
 * GPU driver defaults to "none" when the gpu step is skipped — mirrors
 * the bash script's else-branch. Only fires once FEATURES has actually
 * been answered: otherwise every prior step's submit would pre-tick
 * the GPU sidebar entry with "none" (since `undefined` FEATURES
 * trivially doesn't include "gpu").
 */
export function normalizeAnswers(a: Partial<Answers>): Partial<Answers> {
  const out = { ...a };
  if (out.FEATURES !== undefined && !` ${out.FEATURES} `.includes(" gpu ")) {
    out.GPU_DRIVER = "none";
  }
  return out;
}
