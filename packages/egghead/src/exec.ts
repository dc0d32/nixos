// Spawns scripts/egghead.sh in --non-interactive mode with all
// EGGHEAD_* env vars set from the wizard's answers. Bash sees every
// question pre-answered, skips its prompts, and proceeds straight to
// bridge generation + install handoff.
//
// We exec via spawnSync with stdio inherited so the user sees bash's
// progress output in real time and can answer the (destructive!) YES
// prompt from host-setup.sh at the end. We do NOT swallow stdin.
import { spawnSync } from "node:child_process";
import { Answers } from "./steps.js";

export interface ExecOptions {
  scriptPath: string;
  forwardedArgs: string[];
  /**
   * When true (TUI confirm path), set EGGHEAD_PROCEED=yes so bash
   * skips its final confirmation. When false, leave whatever the
   * caller put in process.env alone — bash defaults to a safe "no"
   * if it's not set anywhere.
   */
  forceProceed: boolean;
}

/**
 * Build the env block we pass to bash. We start from process.env so
 * the user's own EGGHEAD_* overrides (e.g. EGGHEAD_DEFAULT_STATE_VERSION
 * baked into the Nix wrapper) survive, then layer the TUI's answers on
 * top. EGGHEAD_PROCEED is only forced when `forceProceed` is true.
 */
export function buildEnv(
  answers: Answers,
  forceProceed: boolean,
): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const [k, v] of Object.entries(answers)) {
    env[`EGGHEAD_${k}`] = String(v);
  }
  if (forceProceed) {
    env.EGGHEAD_PROCEED = "yes";
  }
  return env;
}

export function execBashWizard(
  answers: Answers,
  opts: ExecOptions,
): { code: number } {
  const env = buildEnv(answers, opts.forceProceed);
  // --non-interactive: bash's `ask` helpers will use env vars without
  // prompting, and will hard-fail if any required answer is missing
  // (defensive: should never trigger because the TUI fills them all).
  const args = ["--non-interactive", ...opts.forwardedArgs];
  const result = spawnSync(opts.scriptPath, args, {
    stdio: "inherit",
    env,
  });
  if (result.error) {
    process.stderr.write(`egghead-tui: failed to exec bash: ${result.error.message}\n`);
    return { code: 127 };
  }
  return { code: result.status ?? 0 };
}
