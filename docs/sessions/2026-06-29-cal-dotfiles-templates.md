# 2026-06-29 — borrow from a stranger's dotfiles: nix flake templates + shell nuggets

## Trigger

Asked to study [Calsjunior/dotfiles](https://github.com/Calsjunior/dotfiles)
and adopt anything worthwhile. That repo is a clean *classic*
options-pattern flake: `enable` flags per feature, home-manager wired in
as a NixOS module, hyprland/zen/kitty/neovim. None of its architecture
fits here — our dendritic flake-parts tree, standalone HM, importing-is-
enabling, impermanence, restic backup, biometrics are all strictly more
capable, and HM-as-NixOS-module + per-feature `enable` gates are exactly
what AGENTS.md forbids. So the take was narrow: a few small, self-
contained quality-of-life nuggets.

## Adopted

- **`flake.templates` output** — new `flake-modules/templates.nix` plus a
  `templates/` tree, pairing with the existing direnv + nix-direnv setup
  so `nix flake init -t ~/nixos#<name>` drops a `flake.nix` + `.envrc`
  (`use flake`) and the toolchain auto-loads on `cd`.
- **`ns`** — fzf + nix-search-tv nixpkgs search wrapper (zsh.nix), reading
  `${nix-search-tv.src}/nixpkgs.sh` (their trick).
- **`comma` + `programs.nix-index`** — `, cowsay hi` runs uninstalled
  programs; nix-index keeps nix-locate's DB warm and provides the
  command-not-found handler.
- **fzf preview + `zoxide --cmd cd`** — eza/bat live preview in fzf, cd via
  frecency.
- **`NH_FLAKE=$HOME/nixos`** — nh is already in dev-shell; this lets
  `nh os switch` / `nh home switch` skip the path arg. Deliberately did
  NOT enable `programs.nh.clean`: it would collide with our custom
  two-stage GC in nix-settings.nix.

## Templates: not cal's, ours

Cal's web/c-cpp pair was a poor fit. Replaced with 9 keyed to an applied/
data-scientist + family workflow (cpp+rust merged → `systems`; webdata+
data merged → `datasci` per request): `python`, `inference`, `slm`,
`systems`, `embedded`, `docker`, `openwrt`, `datasci`, `paper`.

Design decisions:

- Templates track **nixpkgs-unstable independently** of this flake's
  pinned 26.05 — a scratch shell shouldn't be chained to the system
  channel.
- Python-flavoured templates (`python`, `inference`, `slm`, `datasci`)
  lean on **uv** so heavy ML/web wheels come from PyPI rather than
  dragging huge closures through nix; `stdenv.cc.cc.lib`+zlib on
  `LD_LIBRARY_PATH` so torch's dlopen works.
- **No flake.lock shipped** in templates — fresh projects lock current on
  first init.
- Dropped `gguf-tools` (absent from nixpkgs); llama.cpp covers GGUF
  quant/inspect.

## Gotchas

- `templates/*/.envrc` is caught by the root `.gitignore`'s `.envrc` rule;
  needs `git add -f`. Flake builds only see git-tracked files, so each new
  template file had to be staged before eval.
- `programs.command-not-found` is a NixOS option, not HM — don't try to
  disable it inside the HM zsh module; the nix-index HM module owns the
  handler.

## Verification

`paper` init+build verified end-to-end (typst 0.15, tectonic 0.16). All 9
devShells eval; `nix flake init -t` scaffolds correctly. HM + pb-x1
toplevel build; `nh`/`comma`/`ns` resolve in the profile;
`NIXOS_ALLOW_PLACEHOLDER=1 nix flake check --impure` passes.

## Not committed — awaiting user authorization.
