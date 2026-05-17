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
import { existsSync, readFileSync } from "node:fs";

// TPM2 autodetect for the LUKS_TPM step's default. systemd's
// /dev/tpmrm0 is the resource-managed TPM2 device exposed by the
// kernel's TPM2 stack — present on essentially every modern x86
// laptop (SL3, ThinkPad T480+, etc.). Live ISO env decides this once
// at module load; if you toggle hardware between wizard runs, restart
// the wizard.
const tpm2Detected = existsSync("/dev/tpmrm0");

// Secure Boot state detection. The EFI variable "SecureBoot" under the
// EFI_GLOBAL_VARIABLE GUID 8be4df61-93ca-11d2-aa0d-00e098032b8c holds a
// one-byte boolean (after a 4-byte EFI attribute header). When SB is
// disabled, PCR 7 (which TPM2 unlock seals against) still gets
// extended — just with a value that says "SB-disabled". The TPM will
// happily release the key for any kernel that boots on this firmware,
// so the wizard warns when SB is off so the operator understands the
// reduced threat model. "unknown" covers BIOS / pre-UEFI / unreadable
// efivars / non-systemd ISOs.
const SB_EFIVAR =
  "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c";
function detectSecureBoot(): "enabled" | "disabled" | "unknown" {
  if (!existsSync(SB_EFIVAR)) return "unknown";
  try {
    const buf = readFileSync(SB_EFIVAR);
    const last = buf[buf.length - 1];
    if (last === 1) return "enabled";
    if (last === 0) return "disabled";
    return "unknown";
  } catch {
    return "unknown";
  }
}
const secureBootState = detectSecureBoot();

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
  // Raw LUKS passphrase. Stays in process env / tmpfs only;
  // bash writes it to /run/egghead-luks.key and shreds after install.
  // Required when LUKS=yes (used for both the install-time format and,
  // when LUKS_TPM=yes, to seed the TPM2 enrollment).
  LUKS_PASSPHRASE: string;
  // yes/no — when yes, enroll a TPM2 keyslot bound to PCR 7 after
  // install. Passphrase keyslot stays as fallback.
  LUKS_TPM: string;
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
    help: "When yes, the wizard collects a passphrase, installs non-interactively, and (if a TPM2 device is present) optionally enrolls a TPM2 keyslot so the disk auto-unlocks at boot. The passphrase remains as a fallback keyslot.",
    defaultFrom: () => envOr("LUKS", "no"),
  },
  {
    key: "LUKS_PASSPHRASE",
    kind: "password",
    prompt: "LUKS passphrase",
    help: "Used by disko to format the LUKS container and, if TPM unlock is enabled, to enroll the TPM2 keyslot. Kept in tmpfs only; never committed.",
    defaultFrom: () => envOr("LUKS_PASSPHRASE", ""),
    secret: true,
    shouldRun: (p) => p.LUKS === "yes",
    validate: (v, p) =>
      p.LUKS === "yes" && v.length === 0
        ? "LUKS passphrase cannot be empty"
        : undefined,
  },
  {
    key: "LUKS_TPM",
    kind: "yesno",
    prompt: "auto-unlock with TPM2 at boot?",
    help:
      "Enrolls a TPM2 keyslot bound to PCR 7 (Secure Boot state). " +
      "Passphrase keyslot stays as fallback. Default tracks /dev/tpmrm0 presence." +
      (secureBootState === "disabled"
        ? " ⚠ Secure Boot is DISABLED on this host — TPM unlock still works, but PCR 7 binding offers NO protection against an attacker who boots their own kernel on this laptop. Disk is only encrypted against an SSD-only thief."
        : secureBootState === "unknown"
        ? " (Could not detect Secure Boot state; assuming UEFI defaults.)"
        : ""),
    defaultFrom: () =>
      envOr("LUKS_TPM", tpm2Detected ? "yes" : "no"),
    shouldRun: (p) => p.LUKS === "yes",
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
 *
 * LUKS_PASSPHRASE / LUKS_TPM get the same skip-side cleanup: when
 * LUKS=no, both are forced to "" / "no" so the bash side never sees
 * stale env values from a partial back-then-forward navigation.
 */
export function normalizeAnswers(a: Partial<Answers>): Partial<Answers> {
  const out = { ...a };
  if (out.FEATURES !== undefined && !` ${out.FEATURES} `.includes(" gpu ")) {
    out.GPU_DRIVER = "none";
  }
  if (out.LUKS === "no") {
    out.LUKS_PASSPHRASE = "";
    out.LUKS_TPM = "no";
  }
  return out;
}
