# 2026-11-17 — Maths tooling for the kids: `Maths` VS Code profile + `mathkit`

## Locked-in preferences (this session)

- **No AI for maths.** The kids may use AI for programming, not for maths.
  Switching it off is per-profile and only a nudge (a local VS Code cannot
  enforce it); the owner accepted that.
- **Laptop only.** No server, no browser access, no microVM. The owner works
  at Microsoft and is fine with unfree Microsoft extensions.
- **Python, not a new language.** The kids already know Python, so symbolic
  maths is SymPy rather than Maxima/wxMaxima.
- **No commit-and-push shortcuts.** This work was committed on explicit
  instruction; it was NOT pushed.

## What was built

- `flake-modules/math-tools.nix` (kid bundle only): one Python environment
  (SymPy, NumPy, SciPy, Matplotlib, ipykernel, ipywidgets, **notebook**,
  JupyterLab, `mathkit`), reused by `math-python`, the "Maths (Python +
  SymPy)" Jupyter kernelspec, `math-lab` and the VS Code profile; the
  `Maths` VS Code profile; a "Maths Studio" launcher
  (`code --profile Maths ~/math`); starter notebooks seeded into `~/math`
  (only when missing).
- `flake-modules/solvespace.nix` (kid bundle): constraint-based sketching for
  geometry homework.
- `packages/mathkit/`: answer checker (`check`, never reveals the answer),
  step-by-step working (`diff_steps`, `integrate_steps`, `solve_steps`,
  `factor_steps`, `expand_steps`, `frac_steps`, `prime_factors`,
  `long_division`, `gcd_lcm_steps`), visuals (`plot`, `fraction_bar`,
  `compare_fractions`, `numberline`, `tangent`, `riemann`, `unit_circle`,
  `explore_*`), seven starter notebooks, 49 unittest tests.
- The `homelab/` GeoGebra stack also gained GeoGebra Discovery
  (`/discovery/`); see `homelab/sessions/2026-11-17-geogebra-discovery.md`.

## Decisions and why

1. **Desktop VS Code with a Home Manager profile, not a server.** A
   `mathcode`-style multi-user server was designed (microVM on Andromeda, one
   code-server per user behind Authentik) and then dropped once the tests below
   showed the browser route is weaker than the laptop for this audience.
2. **Declaring a non-default profile forces `mutableExtensionsDir = false`**
   (Home Manager asserts this). So extensions the kids install by hand no
   longer persist; add them to the profile instead. `vscode.nix` is shared
   with adult hosts, so the profile lives in `math-tools.nix` and the kid
   bundle forces the setting there. Adult configs were evaluated and are
   unchanged (`mutableExtensionsDir` still true, no profiles).
3. **Extensions come from nixpkgs** (`ms-python.python`, Pylance, debugpy,
   `ms-toolsai.jupyter` and companions), pinned and reproducible.
4. **The environment must contain `notebook`.** With only `ipykernel`, VS Code
   fails to start the kernel ("requires the notebook package") and then
   suggests `uv venv`, which cannot work against a Nix store Python.
5. **A registered kernelspec** (`mathpython`) means the kernel picker shows a
   single "Maths (Python + SymPy)" entry instead of the "Create Python
   Environment" trap; the first run in a notebook still needs one click.
6. **Steps render as Markdown, not LaTeX.** Every math fragment is a `$$`
   block built from real SymPy objects. `_repr_latex_` was removed so VS Code
   and JupyterLab pick one representation. Blank lines between blocks matter:
   without them Markdown folds step titles into the previous paragraph.
7. **Import order in notebooks:** `from sympy import *` BEFORE
   `from mathkit import *`, otherwise SymPy's `plot` shadows mathkit's.

## Test findings (throwaway, all removed)

- `code serve-web` (Microsoft server) in a container: Python, Pylance and
  Jupyter install from the Microsoft marketplace; SymPy LaTeX and Matplotlib
  render; **ipywidgets do not render** (blank output, next cell stalls), even
  with `jupyter.widgetScriptSources`. JupyterLab renders them fine. Desktop
  VS Code 1.119 with the same extensions renders sliders and interacts.
- Browser VS Code stores user settings in the browser, not on the server;
  server-side `User`/`Machine` settings and `product.json` defaults did not
  apply. Workspace `.vscode/settings.json` does, after the folder is trusted.
- A fresh VS Code profile shows a Copilot sign-in onboarding wizard once; it
  is dismissable.
- Browser VS Code loads webviews from `*.vscode-cdn.net`, so browsers need
  internet access.
- VS Code's server needs generous limits: ~1.8 GiB RAM and a few hundred
  processes per active user; a 4 GiB / 512-pid container OOM-killed Pylance.
- Network facts for any future server: the edge proxy is a microVM on Ursa
  (VLAN 60, `192.168.60.2`); ares allows DMZ->trusted only per IP:port
  (`openwrt/fleet/dmz.nix` `dmzBackends`), so a new backend port needs a
  router change. A host-only bridge on Andromeda with one forwarded port would
  avoid that.

## Verification

- `m@pb-t480`, `s@pb-t480`, `m@m-pc` home-manager generations build on
  Andromeda; the generated profile has the pinned extensions, settings,
  kernelspec and seeding activation; `mathkit` imports and its 49 tests pass
  under the Linux environment.
- End-to-end on a Mac with the same nixpkgs VS Code and extensions: the
  notebook ran on the "Maths" kernel, step output rendered as typeset maths,
  `explore_tangent` rendered.
- NOT done: nothing was activated on the kids' machines; they pick it up on
  their next home-manager run / auto-update after a push.

## Known gaps / follow-ups

- `check()` is a nudge, not a grader; `integrate_steps` depends on SymPy's
  `manualintegrate` rule objects and falls back honestly when a rule is unknown.
- Plots have a white background on VS Code's dark theme.
- The one-click kernel choice per notebook is a VS Code behaviour; worth
  revisiting if it annoys the kids.
