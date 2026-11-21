# 2026-11-20 — Maths workspace as a direnv project (replaces the VS Code profile)

## Locked-in preferences (this session)

- **Let VS Code own VS Code; let Nix own the Python.** "VS Code doesn't like the
  Nix way, we're forcing something." Do not declare VS Code's internal state from
  home-manager.
- **No JupyterLab.** VS Code is the notebook surface.
- **Disabling AI is no longer a goal.** No AI-off settings anywhere.
- **Fewest moving parts, no surprises for the kids** ranked above pinned editor
  extensions.
- Nothing is committed or pushed without the owner's explicit say-so.

## What was wrong with the first design (2026-11-17, pushed as 86213c8/75f4725)

Home-manager's `programs.vscode.profiles.Maths` broke on the t480 in three ways:

1. `hm switch` failed: a named profile forces `mutableExtensionsDir = false`, so
   `~/.vscode/extensions` must become a store symlink, which clashes with the
   real directory VS Code already made. The unattended `hm-auto-upgrade` runs
   without a backup flag, so it would have failed too (checked: no `-b` in
   `flake-modules/*auto*`).
2. Profile `settings.json` is a read-only store link, so VS Code popped up
   "cannot write settings".
3. "No Python found" at the kernel picker (see "The interpreter trap" below; the
   profile route never got this far).

Each attempt to fix one of these by declaring more of VS Code's state (a
standalone launcher with its own copied extension folder and a hand-written
`extensions.json`) was the same mistake in a new place, and every test of them
ran on a Mac, never on the Linux path the kids use.

## The design

`~/src/math` is a plain project folder, seeded once (copy-if-missing) by
`flake-modules/math-tools.nix`:

- `.envrc` -> `use flake github:dc0d32/nixos?dir=maths`; direnv builds the Python
  environment on first use and links it at `.direnv/python`.
- `.vscode/settings.json` and `.vscode/extensions.json` (recommended
  extensions): VS Code's own per-folder mechanism.
- `samples/` -> the notebooks from `packages/mathkit/notebooks`.
- `math-studio` (also the "Maths Studio" launcher): prepares the folder, builds
  the environment in a terminal the first time, lets VS Code install the
  recommended extensions with its own CLI (`code --install-extension`, only the
  missing ones) and opens the folder in the kids' normal VS Code with
  `--disable-workspace-trust`.
- home-manager touches nothing of VS Code's, so there is nothing to clash with.

### Why a flake of its own (`maths/`)

direnv's `use flake` fetches **every input** of the flake it is given. Pointing it
at the repo's root flake pulled in unrelated inputs and failed on the unreachable
`spectrum-os.org` (73 s, error). `maths/flake.nix` has nixpkgs as its only input:
4 s first build, 0.13 s on reopen. Its `flake.lock` is separate from the fleet's
(pinned to the same nixpkgs rev, f1e5c35); after a fleet nixpkgs bump run
`scripts/sync-maths-lock.sh` or the kids' Python just stays on the old pin.
`maths/default.nix` defines the environment once for both the flake and
`checks.mathkit` (the unit tests + headless notebook run in `nix flake check`).

### The interpreter trap (found only by testing on Linux)

With `python.defaultInterpreterPath` pointing at the folder link, the kernel
picker showed only "Create Python Environment" and "Install Python" — the exact
symptom reported on the t480. The cause is VS Code's newer Python Environments
extension, which ignores that setting. `"python.useEnvironmentsExtension": false`
in the folder settings restores the classic discovery: the notebook then opens
with `Python 3.13.17` already selected and no picker.

A notebook passed on the command line opened as raw JSON text until the folder
settings pinned `"workbench.editorAssociations": {"*.ipynb": "jupyter-notebook"}`.

Notebooks now declare the standard `python3` kernel (not the removed
`mathpython`). `math-setup` repoints old `mathpython` notebooks (only that
metadata line; the kids' edits are untouched) — verified over an account holding
old notebooks, one edited.

## Verification (Linux: Andromeda, real nixpkgs VS Code 1.119 under Xvfb)

- Brand-new account, shipped launcher only: it seeded the folder, built the
  environment, installed Python/Pylance/Jupyter through VS Code, and opened the
  notebook as a notebook with no popup or toast.
- Cells ran with the Nix Python (SymPy 1.14, `mathkit`): typeset steps
  (`integrate_steps`), `check()` ("Not quite yet…" without the answer), a
  Riemann-sum plot with a working `n` slider and `kind` dropdown (ipywidgets
  work on desktop VS Code), 0 errors.
- The three kid home-manager generations contain no `.vscode`, no
  `~/.config/Code`, no kernelspec and no JupyterLab.
- `nix build .#checks.x86_64-linux.mathkit`: 49 tests pass.
- NOT done: nothing was activated on any real kid laptop; nothing was pushed.
  The first-launch path from the desktop entry (which opens a terminal via
  alacritty when there is no tty) was not exercised, only the tty path.

## Known limits

- Extensions are not Nix-pinned: VS Code installs compatible versions itself
  (needs internet on first launch).
- **Environment refresh.** `.envrc` keeps a stamp (`.direnv/refreshed`) that
  nix-direnv watches: the first time the folder is used after a week without a
  rebuild, the stamp is touched and the environment is rebuilt from
  `maths/flake.lock`. Tested: a stale stamp re-evaluates; a fresh one uses the
  cache; if the rebuild fails (flake unreachable) nix-direnv falls back to the
  previous working environment and retries on every later entry until it
  succeeds. The launcher opens a terminal for that rebuild so progress is visible.
- What the rebuild rebuilds *to* is `maths/flake.lock`, which does not follow the
  fleet by itself: after any nixpkgs bump run `scripts/sync-maths-lock.sh` and
  commit both locks (documented in README.md, AGENTS.md and CLAUDE.md). Not wired
  into the scheduled `update-flake-lock.yml`: that pipeline is a hardened,
  heavily tested script chain, and a maths failure should not gate fleet updates.
- Improvements to `mathkit` or the notebooks reach existing folders only through
  the environment refresh (mathkit) or by deleting the file (notebooks).
  Seeded files, including `.envrc`, are copy-if-missing, so a changed template
  `.envrc` does not reach folders that already have one.
- `maths/flake.nix` covers x86_64/aarch64 Linux only.

## t480 cleanup after this lands

`hm -b backup` left backups of VS Code files behind. The old profile's links are
removed by the next `home-manager switch`; if `~/.vscode/extensions.backup`
exists (the kid's original extensions), move it back to `~/.vscode/extensions`.
Delete `~/src/math/samples` notebooks only if they are unedited copies.
