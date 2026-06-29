# templates — `nix flake init -t` scaffolds for per-project dev shells.
#
# Why: pairs with flake-modules/direnv.nix (`use flake` + nix-direnv).
# Drop a ready-made flake.nix + .envrc into a fresh project and direnv
# auto-loads the toolchain on `cd`:
#   nix flake init -t ~/nixos#<name>
# Tailored to an applied/data-scientist + family workflow (ML/SLM,
# web-data, embedded, firmware) rather than generic web stacks.
#
# The template flakes track nixpkgs-unstable independently of this
# flake's pinned 26.05 — a scratch project shell shouldn't be chained
# to the system channel. Each carries its own .envrc (`use flake`).
# Python-flavoured templates lean on uv for venvs so ML wheels come
# from PyPI rather than dragging huge closures through nix.
#
# Retire when: replaced by a richer scaffolder (devenv/flake-parts
# templates) or per-project shells stop using nix-direnv.
{
  flake.templates =
    let
      mk = description: name: { path = ../templates/${name}; inherit description; };
    in
    {
      python = mk "Python dev (uv + ruff + basedpyright)" "python";
      inference = mk "Python inference one-offs (uv + pip-pulled ML libs)" "inference";
      slm = mk "Run/experiment/dissect small language models" "slm";
      systems = mk "C/C++ and Rust toolchains" "systems";
      embedded = mk "Embedded ARM toolchain + flashing/debug" "embedded";
      docker = mk "Container build/dev (buildx, compose, dive)" "docker";
      openwrt = mk "OpenWrt firmware build host deps" "openwrt";
      datasci = mk "Data + web-data science (duckdb/polars + scraping)" "datasci";
      paper = mk "Typst + LaTeX writeups" "paper";
    };
}
