// Wizard answers + step definitions. Each step is one screen in the
// TUI. The order here matches scripts/egghead.sh main() (lines
// 622-704); any new question added there must also appear here so the
// TUI keeps prompting for it.
//
// "kind" determines which Ink primitive renders the step:
//   - "text"   → ink-text-input
//   - "choice" → ink-select-input
//   - "yesno"  → ink-select-input over ["yes","no"]
//
// "defaultFrom" is a function so role-dependent defaults are evaluated
// lazily (after the role is picked).
import { envOr, defaultStateVersion } from "./env.js";
import { Role, roleByName } from "./roles.js";

export interface Answers {
  HOSTNAME: string;
  ROLE: string;
  DISK: string;
  PRIMARY_USER: string;
  PRIMARY_FULLNAME: string;
  PRIMARY_HM: string;
  EXTRA_USERS: string;
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

export type StepKind = "text" | "choice" | "yesno" | "multi";

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
    key: "EXTRA_USERS",
    kind: "text",
    prompt: "extra users",
    help: 'semicolon tuples "login:fullname:profile". Empty for none. Example: m:M:kid;s:S:kid',
    defaultFrom: () => envOr("EXTRA_USERS", ""),
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
    kind: "text",
    prompt: "root initial password (empty = no root login)",
    help: "Plain text; rotate on first boot. Console + SSH recovery if X breaks. Default 'recovery' is fine for a freshly-installed host.",
    defaultFrom: () => envOr("ROOT_PASSWORD", "recovery"),
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
 * the bash script's else-branch (egghead.sh line 669).
 */
export function normalizeAnswers(a: Partial<Answers>): Partial<Answers> {
  const out = { ...a };
  if (!` ${out.FEATURES ?? ""} `.includes(" gpu ")) {
    out.GPU_DRIVER = "none";
  }
  return out;
}
