# 2026-06-23 — pb-mb: standalone home-manager on the M4 Air (aarch64-darwin)

**Change:** added a new host bridge `flake-modules/hosts/pb-mb.nix`
publishing `homeConfigurations."p@pb-mb"` for the MacBook Air M4, and
made two shared HM feature modules (`fonts`, `nix-settings`)
cross-platform so the `dev` bundle evaluates on macOS. No
`nixosConfiguration`, no nix-darwin — userland only, reversible to
vanilla macOS without a repave.

## Motivation

Explore userland customizations on the Mac while keeping a clean exit:
"if I don't keep it, I want to go back to vanilla macOS on my M4 Air
without repaving." That maps exactly onto the long-standing AGENTS.md
rule that home-manager stays standalone ("so the same user modules can
apply on macOS later"). The two layers and their teardown:

- **Nix itself** (Determinate Systems installer) owns the only system
  footprint: `/nix` APFS volume, `_nixbld*` users, `/etc/{zshrc,bashrc}`
  hooks → `/nix/nix-installer uninstall`.
- **home-manager** writes only under `$HOME` (profile, dotfile symlinks,
  `~/Library/LaunchAgents`, `~/Library/Fonts/HomeManager/`) → `home-manager
  uninstall`.

nix-darwin was explicitly rejected: it is the layer that mutates `/etc`,
launchd *daemons*, and `defaults`, which is the system footprint this
host is designed to avoid.

## What was done

1. **`flake-modules/fonts.nix` → cross-platform.** Hoisted the face list
   into a `fontPkgs = pkgs: …` factory (excluding console-only
   `cozette`) shared by the NixOS side and the new darwin HM branch. The
   HM module is now `lib.mkMerge` of:
   - `isLinux`: the existing fontconfig rendering policy (packages still
     come from the NixOS side).
   - `isDarwin`: installs `fontPkgs` into the profile **and** a
     `home.activation` (`lib.hm.dag.entryAfter ["writeBoundary"]`) step
     that `rm -rf` + re-`ln -sf`s every `*.ttf/*.otf/*.ttc` from a
     `symlinkJoin` of the faces into `~/Library/Fonts/HomeManager/` (Core
     Text only scans fixed dirs; installing into the profile is not
     enough). `find -L … -exec` uses `${pkgs.coreutils}/bin/ln` pinned so
     `$VERBOSE_ARG` is never handed to macOS's BSD `ln`.

2. **`flake-modules/nix-settings-hm.nix` → cross-platform.** This module
   is in the base bundle, so it has to evaluate on macOS. Hoisted the
   two-stage GC into a `gcScript = pkgs: …` and split the scheduler:
   `isLinux` keeps the `systemd.user` service+timer; `isDarwin` runs the
   same script from a `launchd.agents.nix-gc-twostage`
   (`StartCalendarInterval` Sun 03:15, launchd's catch-up mirrors the
   Linux `Persistent=true` weekly timer).

3. **`flake-modules/hosts/pb-mb.nix`** — HM-only bridge. `dev` bundle ++
   `[ alacritty vscode fonts ]`, `home.homeDirectory = "/Users/p"`,
   `stateVersion = "25.11"`. Sets no top-level `git`/`locale` (inherits
   the flake-parts singletons already set by the Linux bridges).

4. **README** — added the `pb-mb` layout line, the `home-manager switch
   --flake .#'p@pb-mb'` day-to-day command, and a "macOS (userland-only)"
   section with the Determinate-installer bootstrap and the two-command
   teardown back to stock macOS.

## Key decisions

- **Username is a single `user = "p"` literal**, like the Linux bridges.
  Considered env-deriving it via `builtins.getEnv "USER"`/`"HOME"` so the
  config adapts to whatever account macOS created, but rejected it:
  standalone HM needs these at eval time, so `getEnv` forces `--impure`
  on every `home-manager switch` and blanks the username under pure eval
  (breaking flag-free smoke-tests). User: "I don't like impure, sounds
  like a landmine for my future self." The literal lives in exactly one
  place and everything derives from it.

- **`aarch64-darwin` is NOT added to `flake-modules/systems.nix`.**
  `homeConfigurations` is published regardless of the `systems` list;
  only the optional `checks.<system>` entry in `home-manager.nix` is
  system-gated. A darwin closure can't be *built* on the Linux dev box
  anyway, so adding the system would only add un-buildable check surface.
  `nix flake check` stays green; smoke-testing happens on the Mac.

- **No new `darwin` bundle.** The pb-mb import list is inlined. A broader
  reorganization of features into "workload" bundles (general-programming
  / ai-tools / terminal-tools / embedded / gui-apps / full-desktop /
  laptop-specific) is tracked as a separate follow-up; pb-mb is a good
  forcing function for it but shouldn't pre-empt it.

## Verification

Eval-only on the x86_64-linux dev box (darwin closures can only be
*built* on a Mac, but evaluation is cross-platform):

- `nix eval --raw .#homeConfigurations.'p@pb-mb'.activationPackage.drvPath`
  → resolves (exercises the dev bundle + alacritty + vscode + the darwin
  branches of fonts and nix-settings).
- `p@pb-x1` HM, `p@wsl` HM, and `pb-x1` NixOS `toplevel` drvPaths all
  still resolve → the cross-platform refactor didn't regress the Linux
  side.
- `nix fmt` clean.

On-Mac activation (`home-manager switch --flake .#'p@pb-mb'`) +
verifying fonts resolve in Alacritty / VS Code is left to the first real
run on the hardware.
