# 2026-04-30 — restore wsl + wsl-arm hosts

The earlier dendritic cleanup commit deleted the legacy
`hosts/{wsl,wsl-arm}/` and `homes/p@{wsl,wsl-arm}/` host bridges.
The feature module `flake-modules/wsl.nix` and the `nixos-wsl` flake
input were preserved, but with no host importing the module, there
were no `nixosConfigurations.{wsl,wsl-arm}` and no
`homeConfigurations.'p@wsl*'` to build. This commit restores both.

## Why one file producing two configurations

A `nixosConfigurations.<name>` entry is keyed by `nixpkgs.hostPlatform`
at evaluation time; one entry can't be both `x86_64-linux` and
`aarch64-linux`. So we need two NixOS configurations (and two HM
configurations) regardless. The question is whether they live in one
host module file or two.

Considered:

- **Two thin host bridges (`wsl.nix`, `wsl-arm.nix`) sharing
  `flake-modules/wsl.nix`.** First draft. Diffed at ~80% identical
  bodies; the user (correctly) flagged it as duplication.
- **One host bridge using `builtins.currentSystem`.** Requires
  `--impure` for every build, breaks `nix flake check` on the
  cross-arch case, prevents cross-evaluation. Rejected.
- **One host bridge declaring BOTH configurations via a let-bound
  helper.** Single file, real DRY, no helper-file plumbing, idiomatic
  dendritic (the host bridge declares configurations directly).
  **Chosen.**

The result: `flake-modules/hosts/wsl.nix` (~135 lines) emits both
`configurations.nixos.{wsl,wsl-arm}` and `configurations.homeManager.'p@{wsl,wsl-arm}'`
from the same shared body. The two configurations differ in exactly
two values: `name` and `system` (and therefore `nixpkgs.hostPlatform`).
Both eval to the same drv paths the two-file version produced, so the
consolidation is a pure refactor.

## Why no top-level `host = { ... }` in this bridge

The flake-modules-level `host` option (declared in
`flake-modules/host.nix`) is a singleton across all hosts. The laptop
bridge sets `host = { name = "laptop"; user = "p"; system = "x86_64-linux"; ... }`.
If the WSL bridge also set it (with different name/system values),
the option system would conflict.

Audit shows that of the four `host.*` fields, only `host.user` is
read by anything (`flake-modules/{wsl,hardware-hacking}.nix`). And
`host.user` is `"p"` everywhere in this repo. So:

- Laptop bridge keeps setting `host = { ... }` for now.
- WSL bridge sets nothing top-level for `host`. It captures `name`,
  `system`, `stateVersion` as local `let`-bindings and uses them
  directly inside each per-config `module = { ... }`.
- This is a latent fragility: if a third host appears with a
  different `user`, both bridges will conflict on `host.user`.

A proper fix is to drop the global `host` option pattern entirely
and let each NixOS configuration carry its own host metadata in a
per-config option (or just inline literals). That's a bigger
refactor, deferred.

## Pattern notes for the WSL bridge

- `config.flake.modules.nixos.wsl` is imported **first** in the
  per-host NixOS module so its `mkForce` overrides win against any
  baseline default a shared module might bring in.
- WSL hosts deliberately import a small subset of feature modules:
  - NixOS side: `wsl`, `nix-settings`, `system-utils`, `users`, `locale`.
  - HM side: `git`, `tmux`, `direnv`, `btop`, `build-deps`, `gh`,
    `ai-cli`, `zsh`, `neovim`. All headless-friendly.
  - Skipped (GUI / hardware): `gpu`, `power`, `networking`, `battery`,
    `audio`, `biometrics`, `login-ly`, `niri`, `fonts`,
    `hardware-hacking`, `polkit-agent`, `chrome`, `bitwarden`,
    `vscode`, `alacritty`, `desktop-extras`, `wallpaper`, `idle`,
    `freecad`, `quickshell`.
- `nixpkgs.hostPlatform` is set explicitly inside the per-host NixOS
  module. On bare-metal hosts that value comes from
  `hardware-configuration.nix`; WSL doesn't generate one (the WSL
  fork supplies its own equivalents), so the host bridge sets it.
- The bridge does NOT declare `users.users.${user}` — the WSL fork
  creates the default user itself. The shell is set to zsh from
  `flake-modules/wsl.nix` via `mkForce`.

## Drive-by hygiene

Removed two stale TODO-style comments left over from the migration:

- `flake-modules/nixos.nix` had a comment claiming `specialArgs` was
  only for the duration of the migration and could be deleted in the
  cleanup commit. Wrong — `inputs` is a permanent dependency for
  modules that pull arbitrary flake inputs (including `wsl.nix` for
  `inputs.nixos-wsl`). Updated the comment to reflect that.
- `flake-modules/home-manager.nix` had the same kind of stale comment.

## Verification

All four x86 builds produce stable hashes:

- `.#nixosConfigurations.laptop.config.system.build.toplevel`
  → `iyji0yr51hv1ix6s5s8l7hc0y6wbpaq3` (byte-identical to baseline,
    no regression from substrate comment edits).
- `.#nixosConfigurations.wsl.config.system.build.toplevel`
  → `f8pc9csn7cp1qzcx753cp80ny7wjb141`.
- `.#homeConfigurations.'p@laptop'.activationPackage`
  → `ds56glplhvl53m19jwfzymairxyg1780` (baseline, no regression).
- `.#homeConfigurations.'p@wsl'.activationPackage`
  → `pr3b9gcyqdfb3ww1hcj1q8z00rlmf4b9`.

The aarch64 configurations evaluate cleanly (drv paths computed):

- `wsl-arm` → `p6wc22697xpb9bmya19696gsr8l288pa-nixos-system-wsl-arm-…`
- `p@wsl-arm` activationPackage drv computed.

The aarch64 derivations were not built — the agent runs on x86_64-linux
without an arm builder or qemu-binfmt. Real builds happen on the
target Windows-on-ARM machine the first time the user runs
`sudo nixos-rebuild switch --flake .#wsl-arm`.

## Open follow-ups

- `git.name` / `git.email` are placeholder `CHANGEME` (matching the
  laptop bridge's existing style); fill in real values before first
  WSL deploy.
- Consider dropping the global `host` option pattern (see "Why no
  top-level `host = { ... }`" above) when convenient.
- If WSL distros end up needing audio (PipeWire-on-WSL is
  experimental but possible) or X11 forwarding, those would be added
  to the `imports` lists; the feature modules already exist.
