# AGENTS.md

## Hard rules

- **Never `git commit` or `git push` without explicit user instruction.**
- Do not wire home-manager into NixOS as a module — HM is standalone
  by design.
- Do not add nix-darwin, a secrets framework (sops-nix/agenix), or
  move configs to a separate dotfiles repo unless asked.
- Line endings must stay LF (enforced by `.gitattributes`).

## Key commands

```sh
# Rebuild NixOS (user runs sudo, not the agent)
sudo nixos-rebuild switch --flake .#pb-x1

# Rebuild user environment
home-manager switch --flake .#'p@pb-x1'

# Format
nix fmt

# Evaluate without building (use --impure if any host is a placeholder;
# see "Placeholder hosts" below)
nix flake check
NIXOS_ALLOW_PLACEHOLDER=1 nix flake check --impure

# Agent-side smoke build (no activation, no sudo)
nix build .#nixosConfigurations.pb-x1.config.system.build.toplevel
nix build .#homeConfigurations.'p@pb-x1'.activationPackage

# Smoke-build a placeholder host (pb-t480, ah-1):
NIXOS_ALLOW_PLACEHOLDER=1 nix build --impure \
    .#nixosConfigurations.pb-t480.config.system.build.toplevel
```

## Placeholder hosts

Hosts whose `hosts/<name>/hardware-configuration.nix` is the all-zeros
sentinel (currently `pb-t480` and `ah-1`) carry an assertion
that aborts evaluation of `system.build.toplevel` unless
`NIXOS_ALLOW_PLACEHOLDER=1` is in the environment. This keeps a real
`sudo nixos-rebuild switch` from accidentally activating an unbootable
config, while still letting smoke-builds proceed on a dev machine.

The host bridge marks the config with `placeholder = true;` so the
auto-generated `flake.checks.<system>.configurations:nixos:<name>`
entry is filtered out — but `nix flake check` itself also walks every
entry in `nixosConfigurations`, which is built-in CLI behavior we
can't suppress. Use `--impure` for `nix flake check` while any host
is still placeholder.

## Architecture

- `flake.nix` is a thin [flake-parts](https://flake.parts) entry point
  that imports the dendritic tree under `flake-modules/` via
  [import-tree](https://github.com/vic/import-tree).
- Every Nix file under `flake-modules/` is a top-level flake-parts
  module. Each feature contributes to
  `flake.modules.<class>.<feature>` for whichever class(es) it applies
  to (`nixos`, `homeManager`, or both as a cross-class module).
- `flake-modules/hosts/pb-x1.nix` is the host bridge for the primary
  laptop: it picks which
  feature modules to import and sets per-host option values.
- **Importing IS enabling.** There is no per-feature `enable` flag and
  no `variables.nix`. Hosts that don't want a feature simply don't
  import it.

## Module conventions

- Pure-leaf modules (no host-tunable data) write
  `flake.modules.<class>.<name> = { … };` at the top level.
- Modules with host-tunable data declare top-level `options.<ns>` and
  contribute via
  `config.flake.modules.<class>.<name> = let cfg = config.<ns>; in { … };`.
  The inner module's `config` shadows the outer one — let-bind `cfg`
  from the **outer** flake-parts `config`.
- When a file mixes `options` with `flake.modules.*`, the latter MUST
  be wrapped in an explicit `config = { … };` block.
- Use `lib.mkDefault` for policy values so hosts can override without
  `mkForce` conflicts.
- Every module file begins with a header explaining (1) why it exists
  and (2) the retirement condition (when it would be safe to delete).
- Overlays live in `overlays/<name>.nix`, registered in
  `overlays/default.nix`. Same (why, retirement) header rule applies.

## Cross-module signals

When feature A needs to know whether feature B is loaded (e.g.
`quickshell` checks `biometrics.enable` to decide lockscreen hints),
feature B declares `options.B.enable = mkOption { default = false; };`
and sets `config.B.enable = lib.mkDefault true;` inside its own module.
Importing B publishes the signal; non-importers get false. No host
coupling required.

## Flake is git-tracked — new files must be staged

Nix flake builds only see **git-tracked** files. After creating any
new file, run `git add <file>` before any rebuild or build, or it will
be silently excluded.

## Shell script shebangs

Always use `#!/usr/bin/env bash` (or `#!/usr/bin/env python3`, etc.)
for scripts in this repo. **Never `#!/bin/bash`.**

NixOS does not ship `/bin/bash` on a default install — only `/bin/sh`
(POSIX shell) and `/usr/bin/env` are guaranteed to exist. WSL hosts
populate `/bin/bash` for compat with Linux tooling that hardcodes the
path, which makes it easy to author a script on WSL that works locally
but fails with `bad interpreter: No such file or directory` the
moment it runs on bare-metal `pb-x1` / `pb-t480` / `ah-1`.

For scripts embedded in `.nix` files, use `pkgs.writeShellApplication`
or `pkgs.writeShellScript` — those generate a Nix-store shebang that's
always valid. Don't hand-write `/bin/bash` paths in Nix-emitted scripts.

The `check-bash-shebang` pre-commit hook (declared in
`flake-modules/dev-shell.nix`) rejects commits that introduce a
hardcoded bash path; `nix flake check` runs the same hook.

## Deploy split: NixOS vs home-manager

- System-level (`flake.modules.nixos.*`): PipeWire, kernel, services,
  boot — `sudo nixos-rebuild switch --flake .#pb-x1`.
- User-level (`flake.modules.homeManager.*`): dotfiles, EasyEffects,
  quickshell, zsh, alacritty — `home-manager switch --flake .#'p@pb-x1'`.
- Editing a `flake.modules.nixos.*` module and only running
  home-manager (or vice versa) silently has no effect.

## Host-specific assets

Hardware-specific files (audio presets, IRS impulse responses,
hardware-configuration.nix) live under `hosts/<hostname>/`, not in
`flake-modules/`. They are referenced from the host bridge as paths
fed into the relevant module's options:

```nix
# flake-modules/hosts/pb-x1.nix
audio.easyeffects = {
  presetsDir = ../../hosts/pb-x1/audio-presets;
  irsDir     = ../../hosts/pb-x1/audio-irs;
  preset     = "X1Yoga7-Dynamic-Detailed";
};
```

## EasyEffects specifics

- Preset JSON files → `~/.config/easyeffects/output/` (via
  `xdg.configFile`).
- IRS impulse response files → `~/.local/share/easyeffects/irs/` (via
  `xdg.dataFile`) — **required**, not optional; the convolver stage in
  every preset references its IRS by `kernel-name`.
- Auto-load is set via `~/.config/easyeffects/db/easyeffectsrc`
  (`[Presets] lastLoadedOutputPreset=<name>`). The
  `last-used-output-preset` text file is **not** read by EasyEffects.
- The existing `easyeffectsrc` will block deployment unless
  `force = true` is set on that `xdg.configFile` entry.

## Quickshell (QML bar/shell)

- QML files live in `flake-modules/quickshell/qml/` and are deployed
  via `xdg.configFile."quickshell"` with `recursive = true`.
- Every new QML type must be registered in
  `flake-modules/quickshell/qml/qmldir` or it won't be found at
  runtime.
- New files must be `git add`-ed before deploying (flake build ignores
  untracked files).
- Use Quickshell for as many shell features as possible. Ask explicit
  user permission before reaching for swaybar/waybar etc.

## Adding a new host

Two paths:

**Wizard (preferred for fresh hosts) — `egghead`:** boot the
official NixOS installer ISO, bring networking up (USB-ethernet
preferred; or `iwctl` / `nmtui` for WiFi), then run

```sh
sudo nix --extra-experimental-features 'nix-command flakes' \
    run github:dc0d32/nixos/disko-and-egghead#egghead
```

A TypeScript+Ink TUI asks for hostname, role (`bare-metal-laptop` /
`bare-metal-desktop` / `vm-headless` / `vm-desktop`), target disk,
users (with HM profiles), feature toggles (presets driven by role),
optional LUKS root encryption, optional root recovery password
(default `recovery` — see "SL3 install safety guardrails" below),
locale, and timezone. It writes
`flake-modules/hosts/<name>.nix` +
`hosts/<name>/hardware-configuration.nix` into a fresh checkout,
commits, and execs `scripts/host-setup.sh --install <name>
--no-regen-hwconfig`. First-boot `egghead-amend.service` reruns
`nixos-generate-config` against the installed kernel and commits
any divergence in the primary user's `~/nixos` clone.

Pre-flight on bare metal:

- **Secure Boot must be OFF in UEFI.** NixOS doesn't ship a
  shim-signed kernel; this includes Microsoft Surface, most OEM
  laptops, and any board with secure boot enabled out of the box.
- **For Microsoft Surface devices** append `surface` to the
  features list when the wizard asks. That imports
  `flake.modules.nixos.surface` (wraps nixos-hardware's
  `microsoft-surface-pro-intel` bundle — patched linux-surface
  kernel, iptsd, thermald, surface-control). Without it
  touchscreen/pen/suspend will be flaky on every Surface device.
- Bridge emits `boot.kernelPackages = lib.mkDefault
  linuxPackages_latest;` so hardware modules that ship their own
  kernel (`microsoft-surface-*`, `lenovo-thinkpad-*`, etc.) can
  override without `mkForce`.

Non-interactive use (tests / golden masters): every prompt is
backed by an `EGGHEAD_<NAME>` env var; pass `--non-interactive` to
skip the TUI entirely (caller must supply all `EGGHEAD_*`). The
bash engine ships separately as `nix run .#egghead-sh` for
headless / no-Node environments. See `nix run .#egghead -- --help`.

## SL3 install safety guardrails

`host-setup.sh --install` runs `guard_disk_safety` before disko's
destructive partition wipe:

- Refuses if the target disk is the live ISO's source
  (parent device of `/`, `/nix`, `/nix/store`, `/iso`,
  `/run/installer`, etc.).
- Refuses if the disk is smaller than 16 GiB.
- Refuses if any partition on the disk is currently mounted.
- Requires the operator to retype the disk's MODEL and SIZE
  (whitespace + case ignored) instead of the old "type YES" prompt.

`--force-disk` (env `FORCE_DISK=1`) bypasses every check and the
typed-back confirmation — ONLY for automated smoke tests; a typo
under it destroys data.

Wizard-generated bridges emit a recovery posture when the operator
sets a non-empty `EGGHEAD_ROOT_PASSWORD` (default `recovery`):
`users.users.root.initialPassword`, plus
`services.openssh.settings { PasswordAuthentication=true;
PermitRootLogin="yes"; }`. The point: if first boot's display
manager / HM activation breaks, `ssh root@<host-ip>` from another
LAN machine still works. Operator's first action post-boot should
be `passwd root` to rotate the plain-text password. The
post-`nixos-install` summary printed by `host-setup.sh` echoes the
configured password and the ssh recipe.

**Hand-rolled (advanced):**

1. Create `flake-modules/hosts/<name>.nix` modeled after `pb-x1.nix`
   (full desktop) or `wsl.nix` (headless / multi-config). Include
   the disko block by importing `config.flake.modules.nixos.disko`
   and the matching layout factory call from
   `config.flake.lib.diskoLayouts.{bare-metal,vm}` with the target
   disk path. Bare-metal hosts use `bare-metal` (hybrid BIOS+UEFI,
   btrfs subvols); Proxmox/NFS-backed VMs use `vm` (UEFI-only, ext4,
   no swap, no subvols).
2. Generate `hosts/<name>/hardware-configuration.nix` via
   `sudo nixos-generate-config --no-filesystems --show-hardware-config`.
   The `--no-filesystems` flag is mandatory — disko owns
   `fileSystems.*` and `swapDevices`, and an emitted block would
   collide. The placeholder pattern shipping with `m-pc`/`ah-1` (an
   assertion gated on `NIXOS_ALLOW_PLACEHOLDER=1`) is the right
   shape for unbuilt hosts.
3. Pick which feature modules to import; set their option values.
4. `git add` everything new and build.
5. To install on real hardware: boot a NixOS live USB, clone this
   flake, then `sudo ./scripts/host-setup.sh --install <name>` — it
   builds the host's `config.system.build.diskoScript`, runs it
   (formats + mounts /mnt), regenerates hwconfig, runs nixos-install,
   then bootstraps each user's home-manager profile.

## Session log

After a substantive session (new subsystem, migration, architectural
decision), write `docs/sessions/YYYY-MM-DD-<slug>.md`. Do not edit
past session files.
