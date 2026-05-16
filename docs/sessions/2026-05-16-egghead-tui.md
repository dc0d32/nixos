# egghead phase 3 — TypeScript + Ink TUI front-end

Phase 3 of the egghead installer wizard plan: replace the bash
prompt loop with a real TUI. Done as an Ink (React-for-CLI) app that
collects the same answers the bash script asks for, then execs the
bash script with `EGGHEAD_*` env vars set so bash does no
re-prompting. Bash remains the engine; TUI is pure front-end.

## What landed

- `packages/egghead/` — new Node package built with `buildNpmPackage`.
  - `src/roles.ts` — role table mirroring `scripts/egghead.sh` lines
    229-260. Duplicated rather than parsed; the catalog is small,
    stable, and human-curated.
  - `src/env.ts` — `EGGHEAD_*` env reader with the same set-vs-empty
    semantics bash uses (`${!name+x}` → `Object.prototype.hasOwnProperty`).
  - `src/lsblk.ts` — best-effort disk listing for the DISK prompt.
  - `src/steps.tsx` — declarative step list (one entry per question)
    with per-step `kind` / `validate` / `shouldRun` / `defaultFrom`.
    Adding a new wizard question is one entry here + one prompt in
    the bash script.
  - `src/app.tsx` — Ink driver: walks steps, accumulates answers,
    renders summary, calls back into `index.tsx` on confirm/abort.
  - `src/exec.ts` — `spawnSync` of the bash script with full stdio
    inheritance (so the operator still sees `host-setup.sh`'s `YES`
    prompt) and only forces `EGGHEAD_PROCEED=yes` on the
    TUI-confirm path; non-TTY / `--non-interactive` flows pass the
    caller's env through unchanged.
  - `src/index.tsx` — argv parsing with `meow`, TTY detection,
    Ink mount or direct bash exec.
  - `default.nix` — `buildNpmPackage` runs `npm ci` + `tsc`, prunes
    dev deps, then `makeWrapper`s a `$out/bin/egghead` shim that
    runs `node $out/lib/.../dist/index.js` with
    `EGGHEAD_BASH_SCRIPT` pre-set and the bash engine's runtime
    binaries on PATH.

- `flake-modules/egghead.nix` — now publishes both:
  - `packages.<system>.egghead` — the TUI (TS+Ink → Node closure
    ~635 MiB; download once, cache forever).
  - `packages.<system>.egghead-sh` — the bash engine as before, for
    headless / no-Node environments.

- `README.md`, `AGENTS.md` — "Adding a new host" section updated to
  mention the TUI + the `egghead-sh` fallback.

## Design decisions

- **TUI is a pure input collector.** It does not duplicate the
  bridge-emission / commit / install logic in TypeScript. Instead it
  walks the same questions, validates inputs locally for fast
  feedback, then execs `scripts/egghead.sh --non-interactive` with
  every answer in the env. This keeps a single source of truth for
  what gets written to disk; the bash script's `ask` helpers already
  accept env vars and skip prompts.
- **`EGGHEAD_PROCEED` semantics deliberately asymmetric.** TUI
  confirm sets it to `yes`. Non-interactive / non-TTY flows leave
  the caller's value alone — bash defaults to a safe `no`-abort if
  it's unset anywhere. A caller who forgot to set `EGGHEAD_PROCEED=yes`
  in CI sees an abort, not a silent disk-wipe.
- **`bin/egghead` (the wrapper) vs `bin/egghead-tui` (the npm bin).**
  The wrapper is what users invoke; it sets `EGGHEAD_BASH_SCRIPT`
  and `PATH` then re-execs node. The raw `egghead-tui` symlink is
  left in place because npm puts it there and removing it would
  fight `buildNpmPackage`; running it directly errors out cleanly
  with a hint.
- **No bundler.** Tried esbuild bundling first; ink pulls
  `yoga-wasm-web` which loads a `.wasm` at runtime, and
  `signal-exit` does dynamic `require()`. Both fight a single-file
  ESM bundle. Cheapest path was `tsc` per-file transpile + shipped
  `node_modules` in the nix store — standard buildNpmPackage shape.
- **`--no-X` flag parsing.** meow rewrites `--no-clone` to
  `clone=false`; declare flags as positive with `default: true`
  and forward `--no-X` to bash when false.
- **Role table duplicated, not parsed.** The bash and TS tables
  must be kept in sync. Tradeoff: a parser is more code than the
  data; the table is 4 rows.

## Verified

- `npm run typecheck` passes; `tsc` builds cleanly.
- Local node run: `node dist/index.js --help` prints help; missing
  `EGGHEAD_BASH_SCRIPT` errors with a helpful message.
- Local node run, non-interactive, all `EGGHEAD_*` set, drives the
  bash script end-to-end against a scratch checkout: bridge written,
  committed, host's toplevel builds clean (with and without LUKS).
- Nix-built `packages.x86_64-linux.egghead`:
  - `$out/bin/egghead --help` works.
  - Non-interactive run via the wrapper produces a valid bridge and
    builds toplevel.
  - All existing hosts (`pb-x1`, `ah-1`) still build; `nix flake
    check --impure` still passes.

## Out of scope / deferred

- **Mouse / window resize / dynamic disk re-list.** The TUI is one
  prompt at a time; no live disk-picker refresh. Operator can
  Ctrl-C and re-run if disks were hotplugged.
- **Custom installer ISO (`installerImage` config) with egghead
  baked in.** Still phase 2 work. Currently `nix run` pulls the
  Node closure from cache.nixos.org over the network at install
  time.
- **TUI screens for post-install tasks** (LUKS rekey, adding extra
  users to an existing host, etc.). All bridge-edit operations are
  hand-rolled today.
- **Test harness.** The non-interactive path is covered by manual
  smoke tests on every change; full integration tests would need a
  pty/screen-scrape framework.
