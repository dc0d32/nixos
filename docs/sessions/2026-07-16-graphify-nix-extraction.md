# 2026-07-16 — graphify-nix: a real Nix code graph (imports, calls, features)

## Trigger

`scripts/graphify-nix` wraps the `graphifyy` code-graph tool to teach it
`.nix` (graphify ships no Nix grammar). The first cut only classified
`.nix` as code and emitted one file node per file — no edges, so the graph
was markdown-only wiring plus disconnected Nix dots. This session built the
extraction out into a genuine graph and evaluated upstreaming it.

Done across the weekend + today, in dependency order: **imports → calls →
bindings → dendritic → tests → upstream eval**.

## What the wrapper now extracts

Four post-processing passes run per `.nix` file inside `_extract_nix`, each
guarded by its own `try/except` so a bug in one can't silently break the
others (a shared guard had once swallowed a `NameError` that zeroed import
edges — see Gotchas):

1. **Import edges** (`context=import`) — the module DAG. `import ./x.nix`
   (`apply_expression(import, path)`) anywhere, plus bare paths in
   `imports = [ … ]` (including `[ … ] ++ bundles ++ [ … ]`
   `binary_expression` forms). 48 edges (host bridges → hardware-config,
   `andromeda → common → alerting/cockpit/…`, openwrt fleet → submodules).

2. **Call edges** (`context=call`) — nixpkgs primitive usage. Callees that
   are dotted selects rooted at `lib.*` / `pkgs.*` / `builtins.*`
   (`lib.mkForce`, `lib.mkDefault`, `pkgs.writeShellApplication`, …). Each
   distinct callee is one shared synthetic `concept` node, giving a reverse
   "which modules use this primitive" view — directly useful for the repo's
   mkForce-vs-mkDefault policy concerns. ~385 Nix call edges, 77 callee
   nodes.

3. **Binding nodes** (`context=binding`, relation `defines`) — the
   structurally significant attrpaths only (NOT every leaf config scalar):
   `flake.modules.<class>.<feature>` (dendritic features),
   `flake.{lib,overlays,packages,checks}.<name>`, and `options.<ns>`. A
   leading `config.` is stripped and a wrapping `config = { … }` attrset is
   made transparent, so all three dendritic spellings converge on one node.
   92 feature + 150 option + 9 flake-output nodes; 296 `defines` edges.

4. **Dendritic consumer edges** (`context=feature-import`) — the payoff.
   Host/consumer `imports = [ config.flake.modules.<c>.<f> ]` (pub) and
   `pub.modules.<c>.<f>` (homelab) link to the SAME feature node the binding
   pass defines, because both key on the two segments after `modules`. 140
   edges. `graphify explain nixfeat_nixos_crowdsec` now shows `crowdsec.nix
   [defines]` alongside `nixtest.nix / ursa.nix / edge-microvm.nix
   [imports]` — a cross-repo (pub + homelab, scanned together) feature
   consumption graph. 46 features carry both a definition and a consumer
   edge.

All passes: **0 ghost edges** across the whole graph.

## The one subtle bug worth remembering: endpoint id keying

graphify assigns a FILE node the raw id `make_id(str(path))` and, in an
`extract()` post-pass, remaps `make_id(str(path))` **and**
`make_id(str(path.resolve()))` → the canonical repo-relative id (e.g.
`flake_modules_hosts_pb_x1`). Our synthetic edges must key their file
endpoint on **exactly** `make_id(str(path.resolve()))` so that remap rewrites
them in lockstep with the nodes. The first attempt keyed on the
extension-less `_file_stem` form (which is the prefix for a file's *symbol*
nodes, not the file node itself) — those endpoints missed the remap table
and were dropped as ghosts, so only 2 edges survived. Keying on the resolved
full path fixed it (48 edges, 0 ghosts). Synthetic target nodes
(`nixcall:` / `nixfeat:` / `nixopt:` / `nixlib:`, all run through `make_id`)
are not file paths, so the remap leaves them untouched and the node we add
carries the same id — no ghost. **All four passes must `make_id()` their
synthetic node ids** (the binding pass initially didn't, which split every
feature into a raw-id definition node and a `make_id` consumer node — two
disconnected halves).

## Tests

`scripts/graphify-nix-test` (new) asserts all four passes on hand-written
fixtures modelling the real dendritic shapes: a pure-leaf feature module, an
options+`config = { … }` module with a `flake.lib` output, and a host bridge
consuming features via both the `config.flake.modules.*` and `pub.modules.*`
spellings. 14 assertions incl. the noise policy (no node for
`services.demo.enable`) and definition/consumer id convergence. It re-execs
under graphify's venv python like the wrapper. **Not** wired into `nix flake
check` — graphify isn't a nixpkgs package and isn't in the build sandbox; it
is a dev-time test. The wrapper gained an `if __name__ == "__main__"` guard
so the test can import it without triggering the CLI.

## Upstream evaluation (graphify-nix-upstream) — decision: keep the wrapper

Should this be contributed to `graphifyy` so the wrapper retires? **No — keep
the wrapper as the durable seam.** Reasoning, from what the build actually
required:

- graphify's config-driven extensibility is **insufficient** for the
  valuable Nix outputs. `LanguageConfig.extra_walk_fn` and `import_handler`
  are **dead hooks** (defined, never invoked); `_resolve_name` isn't called
  for `.nix`. Nix has no `import` node type. So a mere upstream
  `LanguageConfig` would only restore the shallow file-node cut, none of the
  edges. The valuable passes all needed bespoke AST post-processing.
- **Splittable by generality:**
  - *General Nix (upstreamable):* `.nix` in `CODE_EXTENSIONS`, a
    `tree_sitter_nix` registration, and a real `extract_nix()` covering file
    nodes + import edges + `lib/pkgs/builtins` call edges. These apply to any
    Nix repo. The functions here are a ready reference implementation.
  - *Repo/flake-parts-specific (must stay local):* the dendritic feature
    graph — `flake.modules.<class>.<feature>` significance, the
    `config = { … }` normalization, and the `pub.modules.*` vs
    `config.flake.modules.*` consumer convergence. This is idiomatic to THIS
    flake's architecture, not general Nix, and does not belong upstream.
- Therefore retirement is **partial at best**: even if the generic parts
  land upstream, the dendritic layer still needs a local post-pass, so the
  wrapper stays. Also the `{ … }()` label artefact comes from graphify's
  internal `_extract_generic` naming and is only fixable upstream.

**Action taken:** none blocking. Optionally open a graphifyy issue proposing
`extract_nix()` (generic import/call extractors from this session as the
reference) + a note that `extra_walk_fn` is never invoked. If accepted, the
wrapper drops its generic passes and keeps only the dendritic layer. Tracked
low-priority; not a dependency for anything here.

## Files

- `scripts/graphify-nix` — the four passes + `__main__` guard. Pub commits
  `058cd2b` (imports), `8804aae` (calls); bindings/dendritic/tests/guard in
  the commit accompanying this log.
- `scripts/graphify-nix-test` — new dev-time extraction test (14 assertions).
- `graphify-out/` stays gitignored; regenerate with
  `scripts/graphify-nix update /home/p/nixos` (no LLM cost). Both repos'
  post-commit hooks already do this.

## Retirement condition

Delete the wrapper's generic passes if/when graphifyy ships a native
`extract_nix()`; keep the dendritic pass as a local post-pass regardless.
Delete the whole wrapper only if graphify grows a Nix + flake-parts–aware
extractor upstream (unlikely).
