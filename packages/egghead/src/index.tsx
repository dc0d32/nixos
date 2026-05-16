// Entry point. Parses argv (passes most flags straight through to
// scripts/egghead.sh), decides interactive vs non-interactive, and
// either renders the Ink wizard or execs bash directly.
//
// Interactive mode (default when stdin is a TTY and --non-interactive
// is NOT passed):
//   1. Render <App/>.
//   2. On done, exec scripts/egghead.sh --non-interactive with
//      EGGHEAD_* env vars set from the answers + EGGHEAD_PROCEED=yes.
//
// Non-interactive mode:
//   - Skip Ink entirely; exec scripts/egghead.sh with the same args
//     and forward exit code. EGGHEAD_* must come from the caller's
//     environment.
//
// EGGHEAD_BASH_SCRIPT must point at the bash wizard. The Nix wrapper
// sets it to the in-store path; running this file directly without
// that env var will error out with a helpful message.

import React from "react";
import meow from "meow";
import { render } from "ink";
import { App } from "./app.js";
import { execBashWizard } from "./exec.js";
import { Answers } from "./steps.js";

const cli = meow(
  `
  Usage
    $ egghead [options]

  Options (all forwarded to scripts/egghead.sh):
    --workdir DIR       where to put the cloned flake
    --no-clone          skip the clone step
    --no-install        generate bridge + commit, skip nixos-install
    --non-interactive   skip the TUI; require EGGHEAD_* env answers
    --help              show this help

  All wizard answers may be pre-supplied via EGGHEAD_* env vars (see
  scripts/egghead.sh --help for the full list). When the TUI runs,
  those env vars become the pre-filled defaults.
`,
  {
    importMeta: import.meta,
    booleanDefault: undefined,
    flags: {
      workdir: { type: "string" },
      // meow treats --no-X as `X = false`. So we declare the
      // positive form (default true) and forward --no-X to bash when
      // the user passed it.
      clone: { type: "boolean", default: true },
      install: { type: "boolean", default: true },
      nonInteractive: { type: "boolean", default: false },
    },
    autoHelp: true,
    autoVersion: false,
    allowUnknownFlags: true,
  },
);

function flagsToArgv(flags: {
  workdir?: string;
  clone: boolean;
  install: boolean;
}): string[] {
  const out: string[] = [];
  if (typeof flags.workdir === "string") out.push("--workdir", flags.workdir);
  if (!flags.clone) out.push("--no-clone");
  if (!flags.install) out.push("--no-install");
  return out;
}

const scriptPath = process.env.EGGHEAD_BASH_SCRIPT;
if (!scriptPath) {
  process.stderr.write(
    "egghead-tui: EGGHEAD_BASH_SCRIPT is unset.\n" +
      "  This binary is meant to be invoked via the Nix wrapper.\n" +
      "  To use the bash wizard directly: run scripts/egghead.sh\n",
  );
  process.exit(2);
}

const forwarded = flagsToArgv(cli.flags);

if (cli.flags.nonInteractive || !process.stdin.isTTY) {
  // No TUI — exec bash directly. The caller is responsible for
  // setting EGGHEAD_* themselves. We do NOT force EGGHEAD_PROCEED:
  // bash defaults to a safe "no" if unset, so a caller who forgot
  // to confirm gets an abort rather than a silent disk-wipe.
  const { code } = execBashWizard({} as Answers, {
    scriptPath,
    forwardedArgs: forwarded,
    forceProceed: false,
  });
  process.exit(code);
}

const { waitUntilExit } = render(
  <App
    onDone={({ answers, proceed }) => {
      if (!proceed) {
        process.stderr.write("\nabort: nothing written.\n");
        process.exit(1);
      }
      const { code } = execBashWizard(answers, {
        scriptPath,
        forwardedArgs: forwarded,
        forceProceed: true,
      });
      process.exit(code);
    }}
  />,
);

await waitUntilExit();
