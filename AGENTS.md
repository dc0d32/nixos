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

# Smoke-build a placeholder host (pb-t480, m-pc, ah-1):
NIXOS_ALLOW_PLACEHOLDER=1 nix build --impure \
    .#nixosConfigurations.pb-t480.config.system.build.toplevel

# Backup wrappers (installed system-wide when flake.modules.nixos.backup
# is imported by the host bridge — see "Impermanence + backup" below):
sudo backup-snapshots                   # list snapshots in this host's repo
sudo backup-restore                     # restore latest (whole /persist)
sudo backup-restore --include /persist/home/p
./scripts/seed-from-host.sh --from pb-x1 --user p   # pull /persist/home/p
                                                     # from pb-x1's repo
```

## Placeholder hosts

Hosts whose `hosts/<name>/hardware-configuration.nix` is the all-zeros
sentinel (currently `pb-t480`, `m-pc`, and `ah-1`) carry an assertion
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
waybar's bluetooth chip checks `bluetooth.enable`),
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
  waybar, zsh, alacritty — `home-manager switch --flake .#'p@pb-x1'`.
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

## Desktop shell

Bar / launcher / notifications / clipboard history / screenshot live
in `flake-modules/desktop-shell.nix` (HM cross-cutting module). It
wires:

- **waybar** — `programs.waybar.enable` + JSON settings + CSS style.
  niri's workspaces and active window are surfaced via waybar's
  native `niri/workspaces` / `niri/window` modules. Autostarts via
  the HM-provided `waybar.service` (graphical-session.target bound).
- **mako** — notifications, autostarted via `services.mako.enable`.
- **fuzzel** — app launcher, bound to `Super+Space` in niri.nix.
- **cliphist** — clipboard history (text + image), watched by a pair
  of systemd-user units. Picker (`clipboard-pick`) is bound to
  `Mod+Shift+C`.
- **screenshot wrapper** — bash wrapper around grim + slurp + satty.
  Bound to `Print` (region) / `Shift+Print` (whole screen) /
  `Alt+Print` (focused window, niri-native).

Lockscreen lives separately in `flake-modules/lockscreen.nix` (cross-
class because it carries a NixOS-side PAM service): `swaylock-effects`
with `security.pam.services.swaylock.fprintAuth = true`, so on
biometric hosts the fingerprint sensor unlocks alongside the password
prompt. No face unlock on the lockscreen — howdy + swaylock isn't a
thing anyone has wired (trade accepted at the quickshell-retreat
session: see `docs/sessions/`).

Each new HM file under the desktop-shell config needs `git add` before
rebuild — same flake-is-git-tracked caveat applies.

## Adding a new host

1. Create `flake-modules/hosts/<name>.nix` modeled after
   `pb-x1.nix` (bare-metal laptop), `m-pc.nix` (bare-metal desktop),
   `wsl.nix` (headless multi-config WSL), or the future placeholder
   `pb-t480.nix`. Import the disko block by including
   `config.flake.modules.nixos.disko` and the matching layout
   factory call from `config.flake.lib.diskoLayouts.{bare-metal,vm}`
   with the target disk path. Bare-metal hosts use `bare-metal`
   (hybrid BIOS+UEFI, btrfs subvols); Proxmox/NFS-backed VMs use
   `vm` (UEFI-only, ext4, no subvols). Both factories accept an
   optional `swapSize` arg (e.g. `"32G"`); omit it (or pass `null`)
   for no swap partition. LUKS is opt-in via `luks = true;`
   (prompts at install time via the disko TTY askpass).
2. Stub `hosts/<name>/hardware-configuration.nix` with the
   placeholder pattern shipping in `m-pc.nix`/`pb-t480.nix` (an
   assertion gated on `NIXOS_ALLOW_PLACEHOLDER=1`) until you can
   regenerate it on the live hardware.
3. Pick which feature modules to import; set their option values.
4. `git add` everything new — flake builds only see git-tracked
   files.

## Installing on real hardware

This flake uses [`nixos-anywhere`](https://github.com/nix-community/nixos-anywhere)
for fresh installs. Boot the official NixOS installer ISO (or any
kexec image) on the target machine, bring networking up, log in
as `root`, and from a machine that already has this flake checked
out run:

```sh
./scripts/install.sh <hostname> <target-ip>
```

`install.sh` is a thin wrapper around
`nixos-anywhere --flake .#<hostname> --target-host root@<target-ip>`.
It builds the host's closure locally, ships it to the target,
runs disko (formats + mounts), runs `nixos-install`, and reboots.

Pre-flight on bare metal:

- **Secure Boot must be OFF in UEFI.** NixOS doesn't ship a
  shim-signed kernel; this includes Microsoft Surface, most OEM
  laptops, and any board with secure boot enabled out of the box.
- **For Microsoft Surface devices** import
  `flake.modules.nixos.surface` in the host bridge. Without it
  touchscreen/pen/suspend will be flaky on every Surface device.
- Bridge emits `boot.kernelPackages = lib.mkDefault
  linuxPackages_latest;` so hardware modules that ship their own
  kernel (`microsoft-surface-*`, `lenovo-thinkpad-*`, etc.) can
  override without `mkForce`.

After first boot:

1. Regenerate `hosts/<name>/hardware-configuration.nix` against
   the live kernel:
   `sudo nixos-generate-config --no-filesystems --show-hardware-config
   > hosts/<name>/hardware-configuration.nix`
   (the `--no-filesystems` flag is mandatory — disko owns
   `fileSystems.*` and `swapDevices`, and an emitted block would
   collide). Commit + push from inside the host.
2. If the host imports `flake.modules.nixos.backup`, bootstrap the
   restic repo: `./scripts/init-backup.sh`. See "Impermanence +
   backup" below.

## Impermanence + backup

Two coupled features (opt-in per host by importing
`flake.modules.nixos.impermanence` / `flake.modules.nixos.backup`
in the host bridge):

**Impermanence** (`flake-modules/impermanence.nix`) wipes the btrfs
`root` subvol back to an empty RO snapshot (`root-blank`, created by
the disko bare-metal factory at install time) on every boot via a
systemd-stage-1 initrd unit. Anything that should survive lives under
`/persist` and is bind-mounted back into place by upstream
[nix-community/impermanence](https://github.com/nix-community/impermanence).
Per-user state goes through the same module's
`environment.persistence."/persist".users.<login>.{directories,files}`
sub-attribute — browsers, bitwarden, gnupg, freecad/kicad prefs,
~/nixos, ~/Documents, etc. The default list is in
`options.impermanence.userDirectories` and is extended per-host with
plain `environment.persistence."/persist".users.<login>.directories`
in the host bridge.

There is **no separate HM module** for impermanence. The upstream HM
impermanence module is deprecated for standalone HM (it requires
home-manager-as-NixOS-module, which this flake deliberately avoids).
Per-user persistence is therefore entirely NixOS-side.

The 30-day-rolling archive of pre-rollback `root` subvols lives under
`/btrfs_tmp/old_roots/<timestamp>/` on the btrfs top-level; the
initrd unit prunes anything older than 30 days. Useful for recovering
state from "I forgot to add this to the persistence list" mishaps.

**Backup** (`flake-modules/backup.nix`) is one restic-over-SFTP repo
per host targeting a TrueNAS (or any sshd + sftp host) at
`sftp://<user>@<host>:<base>/<hostname>`. Daily timer at 03:00 with
`Persistent=true` (laptop in S3 → fires on wake), `RandomizedDelaySec=30m`,
and an `ExecStartPre` gate that polls `/sys/class/power_supply/AC*`
for up to 4h before running (no AC → exit and retry next timer fire).
Source-side consistency: btrfs RO snapshot of `/persist` mounted at
`/run/restic-snapshots/persist` for the backup window.

Defense against a rogue `nas.lan` on a hostile network: the per-host
SSH key + pinned host key in `/persist/etc/ssh-restic/` plus
`StrictHostKeyChecking=yes` and `BatchMode=yes` make SSH refuse the
handshake on mismatch. The per-host repo password (in
`/persist/etc/restic/host.pass`) symmetric-encrypts every object
client-side; an attacker-controlled destination only ever sees
ciphertext.

One shared `restic-backup` SSH user on the NAS has read+write to its
own host's repo and read-only to every other host's repo, which is
what enables cross-host seeding via
`scripts/seed-from-host.sh --from <other> --user <login>` — it pulls
`/persist/home/<login>` from `<other>`'s repo into the current host's
`/persist/home/<login>`. Seeding never touches `/persist` itself
(system state — machine-id, NetworkManager, SSH host keys — is
always host-specific).

TrueNAS-side one-time setup recipe lives in
`docs/runbooks/truenas-restic.md`. Per-host bootstrap is
`scripts/init-backup.sh`.

## Bootstrapping backup on a host

After `nixos-anywhere` finishes and the host boots, run
`./scripts/init-backup.sh` on the host. The script:

1. Prompts for the repo password (paste from password manager).
   Same password works whether this is a fresh install or a
   reinstall on top of an existing repo — restic accepts the
   pasted password either way.
2. Generates a per-host ed25519 SSH key under
   `/persist/etc/ssh-restic/`.
3. Runs `ssh-copy-id restic-backup@nas.lan` — prompts the NAS
   account password once.
4. Pins the NAS host key into the host's known_hosts.
5. Either `restic init` (fresh repo) or detects an existing repo
   and skips init.

After that the daily timer takes over.

## Session log

After a substantive session (new subsystem, migration, architectural
decision), write `docs/sessions/YYYY-MM-DD-<slug>.md`. Do not edit
past session files.
