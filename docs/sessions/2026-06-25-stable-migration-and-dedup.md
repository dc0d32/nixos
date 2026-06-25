# 2026-06-25 — stable channel migration + host-bridge dedup + niri split

## User preferences locked in this session

- **Stay on the stable nixpkgs channel, not unstable.** The flake had
  silently tracked `nixos-unstable` since inception; the user wants the
  stable release channel. Pinned to **`nixos-26.05`** (latest stable as
  of this session) with home-manager on the matching `release-26.05`.
- **Remove neovim everywhere — "too heavy for now"** — including the
  native-Windows Scoop install, not just the Nix/HM module.
- The user authorized **committing logical chunks** during the session
  (but **not pushing**).

## Correction to a finding from the review earlier this session

During the initial review I reported that the root `nixpkgs` was pinned
to **2026-01-16** while home-manager was 2026-05-15 — a "4-month skew."
That was a **misread of the lock graph**: I read the node literally
keyed `nixpkgs` in `flake.lock`, which is a *transitive* dependency, not
the root input (the root input resolves to node `nixpkgs_4`). The real
root nixpkgs was **2026-05-10**, only ~6 weeks old and consistent with
home-manager. The lesson: resolve `nodes.root.inputs.<name>` before
reading a node's `locked` data. The `nix flake update` was still
worthwhile (everything was ~6 weeks stale) — but the alarming skew did
not exist.

## What changed

### 1. Stable channel migration
- `flake.nix`: `nixpkgs.url` → `github:NixOS/nixpkgs/nixos-26.05`;
  `home-manager.url` → `github:nix-community/home-manager/release-26.05`
  (still `follows = "nixpkgs"`). Other inputs (niri-flake, disko,
  nixos-hardware, git-hooks, nixos-wsl, impermanence) are unchanged —
  niri-flake deliberately keeps its own nixpkgs for cachix hits, the
  rest are rolling and work against stable via `follows`.
- Also removed the stale "migration in progress / ./modules/{nixos,home}"
  comment at the top of `flake.nix` (the dendritic migration completed
  long ago; there is no `./modules/` tree).

#### Consequence: electron-39 is insecure on 26.05
The 26.05 stable channel marks **`electron-39.8.10`** as insecure (EOL),
and the adult-desktop closure still pulls it in (electron-based desktop
apps, e.g. bitwarden-desktop). Without action, every graphical host and
the `p@*` HM configs refuse to evaluate. Fix: allow it in both
nixpkgs-config sites —
- `flake-modules/mk-pkgs.nix` (the HM `pkgs` factory), and
- `flake-modules/nix-settings.nix` (`nixpkgs.config.permittedInsecurePackages`
  for the NixOS side).
**Retire both allows** when the offending apps move to a supported
electron (or pin newer app versions). Headless hosts (ah-1, wsl) and the
kid HM configs were unaffected (no electron-39 app in their closures).

### 2. neovim removed everywhere
- Deleted `flake-modules/neovim.nix` (it was dormant — no bundle or host
  imported it since the 2026-05-02 switch to plain vim).
- Deleted `overlays/nvim-treesitter-pin.nix` (its only consumer was the
  neovim module) and dropped it from `overlays/default.nix`.
- Dropped `"neovim"` from the Windows Scoop toolkit
  (`flake-modules/windows/windows.nix`) and the README Scoop example.
- `vim.nix` is now the single source of `EDITOR`/`VISUAL` (`mkDefault
  "vim"`), replacing per-bridge `home.sessionVariables` and the old
  `programs.vim.defaultEditor` reliance.

### 3. niri.nix split
`flake-modules/niri.nix` was 737 lines, dominated by the keybind table
and window-rules. Split into:
- `flake-modules/niri/binds.nix`
- `flake-modules/niri/window-rules.nix`

Each contributes to the **same merged** `flake.modules.homeManager.niri`
via the flake-parts `deferredModule` merge (`flake-parts.flakeModules.modules`),
so the rendered niri config is byte-identical. niri.nix → 275 lines.

### 4. Host-bridge dedup (the big one)
The three bare-metal graphical bridges (pb-x1, m-pc, pb-t480) each
hand-listed the same ~19 NixOS feature modules and a pile of identical
scalars. Introduced:

- **`flake.lib.bundles.nixos.workstation`** (`bundles/nixos-workstation.nix`)
  — the 19-module bare-metal graphical core (intersection of the three).
- **`flake.lib.bundles.nixos.auto-deploy`** (`bundles/nixos-auto-deploy.nix`)
  — `[auto-upgrade, nixos-clone, hm-auto-upgrade]`, shared by m-pc,
  pb-t480, ah-1, wsl.
- Extended `lib.nix`'s bundles submodule with `options.nixos` (it only
  declared `homeManager` before).

Per-host extras (biometrics, face-unlock, hardware-hacking, timekpr,
chrome-managed, nixos-hardware, disko) stay in the bridges.

**Identical scalars lifted to `mkDefault` in the owning module** (bridges
now only set them when diverging):
- `git.nix` — `name`/`email` default to the `CHANGEME` placeholder.
- `locale.nix` — `timezone`/`lang` default to America/Los_Angeles +
  en_US.UTF-8; also `console.keyMap = mkDefault "us"`.
- `idle.nix` — option defaults changed to 300/420/900 (what every host
  already set).
- `wallpaper.nix` already defaulted `intervalMinutes = 30` — the bridge
  blocks were pure no-ops, deleted.
- `system-utils.nix` — added `git` + `vim` (curl/wget were already
  there), so the per-bridge `environment.systemPackages = [git vim curl
  wget]` blocks are gone (pb-t480 keeps only its `familyActivity`).

### 5. kid-account dedup
`flake-modules/kid-hm.nix` publishes:
- `flake.lib.mkKidHmModule { username; audio; stateVersion ? … }` — the
  per-kid HM module (kid bundle + freecad), used by m-pc and pb-t480.
- `flake.lib.kidTimekprPolicy` — the shared screen-time policy (was
  duplicated verbatim in both bridges).

### 6. Documentation
- `README.md`: corrected the configured-hosts list (was only pb-x1/wsl/
  wsl-arm; now lists all 7), noted the stable channel, removed the
  non-existent `packages/` dir from the layout, added `bundles/`, and
  noted alacritty is Linux-only (macOS uses Terminal.app).
- `docs/README.md` and `CLAUDE.md`: removed the `packages/` references;
  `CLAUDE.md` gained a `bundles/` entry.

## Verification

`nix-instantiate --parse` on every touched file, `nix fmt` (clean), and
a full `nix eval` of every config's derivation path:
all 6 `nixosConfigurations` (pb-x1, pb-t480, m-pc, ah-1, wsl, wsl-arm)
and all 10 `homeConfigurations` evaluate on `nixos-26.05`. A full
`nix build`/`nix flake check` was left to the user / the pre-push smoke
build (network was intermittent during the session).

## Not done / follow-ups

- A real `nix build` of the toplevels (only eval was run here).
- Revisit the `electron-39.8.10` allow once upstream apps update.
- `git.{name,email}` still default to the `CHANGEME` placeholder — set a
  real identity if/when desired.
