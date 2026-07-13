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

Tracked as `graphify-nix-*` in the session DB. In priority order:

1. **Binding nodes.** Emit a node per meaningful `binding`, named by its
   `attrpath`. Focus the high-value ones: `flake.modules.<class>.<feature>`
   (the dendritic features), `options.<ns>`, `imports`, top-level `config.*`.
   Decide a noise policy (don't emit a node for every leaf config scalar).
   Investigate why `_extract_generic` doesn't currently recurse into nested
   bindings (function-boundary / body-field handling) and fix the config or add
   an `extra_walk_fn`.

2. **Import edges (the module DAG).** This is the single most valuable output for
   a dendritic flake. Emit file→file edges for both `import ./x.nix` and the
   members of `imports = [ ./a.nix ../b.nix config.flake.modules... ];`. Nix has
   no import node type, so the standard `import_types`/`import_handler` path
   won't fire — needs a custom walk over `apply_expression`(function=import) +
   list literals assigned to an `imports` attrpath.

3. **Call edges.** Resolve `apply_expression` callees (`lib.mkIf`, `lib.mkForce`,
   `pkgs.caddy.withPlugins`, `lib.genAttrs`, …) from the `function` child
   (`variable_expression.name` or `select_expression.attrpath`) and emit call
   edges. Verify the current `call_*` fields actually resolve names (they may not).

4. **Dendritic semantics.** Surface the feature graph: which files contribute to
   `flake.modules.<class>.<name>`, and which host bridges
   (`flake-modules/hosts/*.nix`, `homelab/nix/hosts/*.nix`) import which features.
   Consider a light post-pass that links a `flake.modules.nixos.foo` definition
   node to every host that imports `pub.modules.nixos.foo`.

5. **Name/label quality.** Dotted attrpaths (`services.caddy.package`) — decide
   labels; strip `function_label_parens` artefacts (`{ ... }()`).

6. **Harden the wrapper.** The shebang hardcodes graphify's venv python
   (`/home/p/.local/share/uv/tools/graphifyy/bin/python`) — discover it instead
   (e.g. resolve `~/.local/bin/graphify` → its interpreter) so it isn't tied to
   the `graphifyy` tool name / `$HOME`.

7. **Upstream vs wrapper.** Evaluate contributing a Nix `LanguageConfig` to
   graphifyy upstream (adds `tree_sitter_nix` + a config in `extract.py`) so the
   wrapper can be retired. If not upstreaming, keep the wrapper as the seam.

8. **Tests.** Validate on representative modules: a pure-leaf module, an
   options+config module (e.g. `flake-modules/homelab/crowdsec.nix`), a host
   bridge (`homelab/nix/hosts/ursa.nix`), an overlay. Assert expected feature
   nodes + import edges appear.

9. **Grammar/ABI watch.** `tree-sitter-nix==0.1.0`; confirm node-type names stay
   stable across graphify's `tree_sitter` core bumps.

## How to iterate

Fast loop (no full rebuild): patch the `_NIX_CONFIG` in `scripts/graphify-nix`,
then in graphify's venv python call
`graphify.extract._extract_generic(Path("<file>.nix"), _NIX_CONFIG)` and inspect
`nodes`/`edges`. Full rebuild + report: `scripts/graphify-nix update /home/p/nixos`.
