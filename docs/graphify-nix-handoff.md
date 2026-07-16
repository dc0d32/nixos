# Handoff: proper Nix (`.nix`) support in graphify

**Status:** a *basic* first cut landed (`scripts/graphify-nix`, commit `ffea1bb`).
It makes graphify parse `.nix` at all — `.nix` is now classified as code, the
grammar (`tree-sitter-nix`) is wired, and each `.nix` yields a file node + its
top-level module-function node (extraction went 123 → 280 files). That's the
floor, not the goal. This doc is the spec for someone to make it genuinely useful.

## What exists now

- `scripts/graphify-nix` — an **in-repo wrapper** that monkeypatches graphify at
  runtime (adds `.nix` to `detect.CODE_EXTENSIONS`, registers a `LanguageConfig`
  in `extract._DISPATCH`), then delegates to `graphify.__main__.main()`. Kept in
  the repo (not patched into site-packages) so it survives `uv tool upgrade`.
- Prereq recorded as a uv `--with` dep: `uv tool install graphifyy --with tree-sitter-nix`.
- Both repos' `post-commit` hooks call the wrapper (`graphify-nix update /home/p/nixos`),
  so the graph auto-refreshes with Nix on every commit.

## Why the current cut is shallow

graphify's generic extractor (`_extract_generic`) is tuned for imperative
class/function/call languages. Nix is declarative: the units are **attribute
bindings** (`name = value;`) and **lambdas**, and there are **no classes** and no
distinct `import` node (import is just `apply_expression(function=import, argument=path)`).
The generic walker currently only surfaces the outermost `function_expression`
per file; nested bindings, imports, and calls are not turned into nodes/edges.

## tree-sitter-nix AST cheat-sheet (verified 2026-07-12)

| node | fields | meaning |
|---|---|---|
| `binding` | `attrpath`, `expression` | `name = value;` — the named definitions |
| `function_expression` | `formals`, `body` | lambda (`{ ... }: body` / `x: body`) |
| `apply_expression` | `function`, `argument` | function application (a "call") |
| `select_expression` | `expression`, `attrpath` | attr access (`lib.mkForce`, `config.services.caddy`) |
| `variable_expression` | `name`(identifier) | a bare identifier |
| `path_expression` | — | `./foo.nix` |
| `inherit` | `attrs` | `inherit (x) a b;` |
| `comment` | — | header/why/retirement narrative (already rich in this repo) |

`import ./x.nix` = `apply_expression` whose `function` is `variable_expression`
"import" and whose `argument` is a `path_expression`.

## The work (todos)

Tracked as `graphify-nix-*` in the session DB. STATUS as of 2026-07-16:
items 1–4, 6, 7, 8 are DONE (see
`docs/sessions/2026-07-16-graphify-nix-extraction.md`). Remaining: 5 (label
quality) and 9 (grammar/ABI watch), both minor.

1. **Binding nodes.** ✅ DONE. Emits nodes for the significant attrpaths only —
   `flake.modules.<class>.<feature>`, `flake.{lib,overlays,packages,checks}.*`,
   `options.<ns>` — with `config.`-stripping + `config = { … }` transparency so
   the three dendritic spellings converge. Noise policy: no node for leaf config
   scalars. (`_extract_generic` never recurses into nested bindings; rather than
   fight its function-boundary handling, we walk the tree ourselves in a
   post-pass.)

2. **Import edges (the module DAG).** ✅ DONE. `import ./x.nix` anywhere + bare
   paths in `imports = [ … ]` incl. `++`-concatenated lists.

3. **Call edges.** ✅ DONE for `lib.*`/`pkgs.*`/`builtins.*` selects (the
   `call_*` config fields did NOT resolve names — done via a custom walk +
   synthetic callee nodes). Bare in-repo helper callees deferred (need scope
   resolution).

4. **Dendritic semantics.** ✅ DONE. Feature nodes link every contributing file
   (`defines`) to every consuming host (`feature-import`), across the pub +
   homelab trees, via the `config.flake.modules.*` / `pub.modules.*` convergence.

5. **Name/label quality.** Dotted attrpaths (`services.caddy.package`) — decide
   labels; strip `function_label_parens` artefacts (`{ ... }()`). NOTE: the
   `{ ... }()` artefact originates in graphify's internal `_extract_generic`
   naming — only fixable upstream (see item 7 decision).

6. **Harden the wrapper.** ✅ DONE. Portable `#!/usr/bin/env python3` + re-exec
   that discovers graphify's venv python from the `graphify` launcher's shebang.

7. **Upstream vs wrapper.** ✅ EVALUATED — decision: KEEP THE WRAPPER. A mere
   `LanguageConfig` can't express the valuable edges (dead `extra_walk_fn` /
   `import_handler` hooks; no Nix import node type); the dendritic layer is
   flake-parts/repo-specific and can't upstream. Generic import/call extractors
   COULD upstream as an `extract_nix()` (low-priority follow-up). Full rationale
   in the 2026-07-16 session log.

8. **Tests.** ✅ DONE. `scripts/graphify-nix-test` — 14 assertions on pure-leaf /
   options+config / host-bridge fixtures incl. noise policy + id convergence.
   Dev-time only (graphify absent from the flake-check sandbox).

9. **Grammar/ABI watch.** `tree-sitter-nix==0.1.0`; confirm node-type names stay
   stable across graphify's `tree_sitter` core bumps.

## How to iterate

Fast loop (no full rebuild): patch the `_NIX_CONFIG` in `scripts/graphify-nix`,
then in graphify's venv python call
`graphify.extract._extract_generic(Path("<file>.nix"), _NIX_CONFIG)` and inspect
`nodes`/`edges`. Full rebuild + report: `scripts/graphify-nix update /home/p/nixos`.
