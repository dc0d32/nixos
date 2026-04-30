# 2026-04-30 — drop the `host` flake-parts singleton

Closes the open follow-up flagged in
`2026-04-30-restore-wsl-hosts.md`. The `host = { name; user; system;
stateVersion; }` option in `flake-modules/host.nix` was a flake-parts
level singleton — one value per flake evaluation, not per
NixOS-configuration. That worked while the only host was laptop;
adding wsl/wsl-arm hosts would have made it conflict the moment any
field differed between hosts.

## What changed

- **Deleted** `flake-modules/host.nix` (declared `options.host = { name;
  user; system; stateVersion; }` at the flake-parts level).
- **Added** `options.users.primary` (string) inside
  `flake-modules/users.nix`. Declared as a NixOS option on the inner
  module function (not at the flake-parts level), so each
  NixOS-configuration carries its own value. No default — leaving it
  unset is a configuration error, surfaced at eval time.
- **Converted** `flake-modules/hardware-hacking.nix` to take a
  function form `{ config, ... }: { ... }` and read
  `config.users.primary` from the inner NixOS config. Previously it
  read the flake-parts singleton `config.host.user`.
- **Refactored** `flake-modules/wsl.nix` similarly:
  - The `wsl.defaultUser` option moved from flake-parts level into
    the inner NixOS module. Default chained from
    `config.users.primary`.
  - Inner module now mixes `options` with config attrs, so the config
    attrs are wrapped in an explicit `config = { ... };` block (per
    AGENTS.md "module conventions" — without the wrapper the module
    system errors with `unsupported attribute '_module'`).
- **Updated host bridges:**
  - `flake-modules/hosts/laptop.nix` — dropped the top-level
    `host = { ... };` block; added `users.primary = user;` inside
    `configurations.nixos.${hostName}.module = { ... };`. Other
    per-host fields (`hostName`, `system`, `stateVersion`) were
    already inlined as locals during the dendritic cleanup, so they
    didn't need migration.
  - `flake-modules/hosts/wsl.nix` — added `users.primary = user;`
    inside `mkNixosModule`. Updated the explanatory comment to
    describe the new model rather than the old singleton workaround.

## Why this is structurally better

Three failure modes are now closed:

1. **Wrong-host-name reads.** Previously, anything that read
   `config.host.name` (nothing did, but a tempting "helpful" addition
   like `networking.hostName = config.host.name;` would have been
   wrong) would always see `"laptop"` regardless of which host you
   were building. With per-NixOS-config options, each module reads
   its own host's value via the inner `config`.
2. **Wrong-arch reads.** Same for `config.host.system`. Now there's no
   such cross-host channel at all.
3. **Conflict on multi-host divergence.** Adding a third host with a
   different `user` would have triggered a "conflicting definition"
   error on `host.user`. Now `users.primary` is per-config; each host
   sets its own and there's no namespace collision.

## Verification

All four x86 outputs are **byte-identical** to the pre-refactor
baseline:

- `.#nixosConfigurations.laptop.config.system.build.toplevel`
  → `iyji0yr51hv1ix6s5s8l7hc0y6wbpaq3-nixos-system-laptop-…`
  (drv path changed from `iyji…` to `whsdlsqgnw3k…` and back to
  `iyji…` — interesting: the .drvPath values differed because the
  `.drv` files reference the substrate's input drvs, but the realised
  store path is identical because the actual derivation script and
  inputs hash to the same bytes. Closure-equivalent regression
  criterion satisfied.)
- `.#nixosConfigurations.wsl.config.system.build.toplevel`
  → `f8pc9csn7cp1qzcx753cp80ny7wjb141`
- `.#homeConfigurations.'p@laptop'.activationPackage`
  → `ds56glplhvl53m19jwfzymairxyg1780`
- `.#homeConfigurations.'p@wsl'.activationPackage`
  → `pr3b9gcyqdfb3ww1hcj1q8z00rlmf4b9`

`wsl-arm` and `p@wsl-arm` evaluate to the same drv paths as before
the refactor (`p6wc22697xpb9bmya19696gsr8l288pa-…` and the matching
HM drv); not built on this x86 agent without an arm builder.

## Pattern note for future feature modules

When a feature module needs to know "the primary user of the host
this NixOS config is for," the correct shape is:

```nix
{ ... }:
{
  flake.modules.nixos.<feature> = { config, ... }: {
    users.users.${config.users.primary}.extraGroups = [ ... ];
  };
}
```

NOT:

```nix
{ config, ... }:    # ← OUTER config (flake-parts)
{
  flake.modules.nixos.<feature> = {
    users.users.${config.host.user}.extraGroups = [ ... ];   # ← wrong
  };
}
```

The outer `config` is a flake-parts singleton; the inner one is
per-NixOS-config. Always reach values that are per-host through the
inner module function's `config` argument.

## Open follow-ups

None. The original `host` follow-up is closed.
