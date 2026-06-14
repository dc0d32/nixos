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

# Backup wrappers (installed system-wide when flake.modules.nixos.backup
# is imported by the host bridge — see "Backup" section below):
sudo backup-snapshots                   # list snapshots in this host's repo
sudo backup-restore                     # restore latest (whole /persist)
sudo backup-restore --include /persist/home/p
sudo backup-restore --from-host pb-x1 \
    --password-file /tmp/pb-x1.pass \
    --seed-from-user p --seed-to-user alice
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
    run github:dc0d32/nixos#egghead
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
   no subvols). Both factories accept an optional `swapSize` arg
   (e.g. `"32G"`); omit it (or pass `null`) for no swap partition.
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

## Migrating a pre-disko host

Hosts that existed before the disko switchover (commit `c24521a`) have
GPT partitions without `disk-main-<role>` partlabels, a stale btrfs FS
label, fewer subvols than the disko factory expects, and no dedicated
swap partition. A `nixos-rebuild switch` against the new bridge hangs
at initrd because the synthesized `fileSystems.*` / `swapDevices` set
references partlabels / subvols that don't exist on disk yet.

Use `scripts/disko-migrate.sh <hostname>` on the affected host:

```sh
sudo ./scripts/disko-migrate.sh <hostname>            # dry-run / plan
sudo ./scripts/disko-migrate.sh <hostname> --yes      # execute
sudo nixos-rebuild boot --flake .#<hostname>          # NOT switch
sudo reboot
```

The script is idempotent (detects what's already correct and skips
it), refuses LUKS and multi-disk hosts, refuses to run on a machine
whose `hostname` differs from the arg. If a swap-partition reshape is
needed (shrink btrfs → shrink nixos partition → add swap partition at
end), the `--yes` run prompts the operator to type back the target
disk's MODEL and SIZE before touching anything. No `resume_offset`
capture or follow-up rebuild needed — disko's swap content type pins
`boot.resumeDevice` to `/dev/disk/by-partlabel/disk-main-swap` at eval
time. Full procedure (plus the hand-rolled fallback for cases the
script declines) lives in
`docs/sessions/2026-05-17-disko-in-place-migration.md`.

## Impermanence + backup

Two coupled features (opt-in per host via egghead, or by importing
`flake.modules.nixos.impermanence` / `flake.modules.nixos.backup` in
the host bridge):

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
what enables cross-host seeding: paste another host's repo password
during install (egghead surfaces this per declared user) and
`backup-restore --seed-from-user <src> --seed-to-user <login>` pulls
`/persist/home/<src>` from the source repo into
`/persist/home/<login>` on the new host. Seeding never touches
`/persist` itself (system state — machine-id, NetworkManager,
SSH host keys — is always host-specific).

TrueNAS-side one-time setup recipe (sshd Match block,
`internal-sftp` jail, dataset layout, `authorized_keys` recipe) lives
in `docs/runbooks/truenas-restic.md`. Re-using an existing repo on
re-install is supported via egghead's `IS_REINSTALL=yes` flow — the
operator pastes the original repo password instead of letting
host-setup.sh generate a fresh one.

## Adding backup to an already-installed host

For a host already on disko + impermanence that wasn't egghead-ed
with backup turned on:

1. Add `config.flake.modules.nixos.backup` to the host's
   bridge `imports = [ … ]`, plus the four `backup.*` overrides for
   `truenasHost`, `truenasUser`, `repoBasePath`, and any per-host
   retention tuning.
2. Generate the SSH key + repo password material into `/persist`
   manually — the helpers expect them at:
     `/persist/etc/restic/host.pass` (any random 30+ char string;
        store it in your password manager)
     `/persist/etc/restic/host.repo` (canonical sftp URL; same
        format as `flake-modules/backup.nix` constructs:
        `sftp:<user>@<host>:<base>/<hostname>`)
     `/persist/etc/ssh-restic/restic_ed25519{,.pub}` (one ssh-keygen
        invocation)
     `/persist/etc/ssh-restic/restic_known_hosts` (one
        `ssh-keyscan` against the NAS, double-checked against an
        out-of-band fingerprint)
   All five files are root-owned (pass file 0600, repo url 0644,
   ssh key 0600, pubkey + known_hosts 0644). See
   `scripts/host-setup.sh:do_install_backup_material` for the exact
   commands the install path uses.
3. Paste the new host's ed25519 pubkey into the NAS's
   `~restic-backup/.ssh/authorized_keys` and create the
   `<repoBasePath>/<hostname>` directory (see runbook).
4. `sudo nixos-rebuild switch --flake .#<hostname>` and wait for
   the next 03:00 timer (or `sudo systemctl start
   restic-backups-host.service` to trigger immediately).

## Migrating a live (pre-impermanence) host to impermanence + backup

Full step-by-step playbook in
[`docs/runbooks/host-migration.md`](docs/runbooks/host-migration.md).
Short version: run `sudo scripts/preimpermanence-backup.sh` on the
live host to push a `preimpermanence`-tagged snapshot of every
impermanence-relevant path (system + each user's `/home/<login>`)
to the NAS, stash the printed repo password + ssh key off-host,
then egghead-refresh with `IS_REINSTALL=yes` (pasting the same
password back in), then `sudo scripts/preimpermanence-restore.sh
--target /mnt/persist` from the installer (or
`preimpermanence-restore.sh` from a recovery-root after first
boot). Snapshot paths align 1:1 with what impermanence persists,
so `restore --target /persist` puts every file where the next
boot's bind-mounts expect to find it. The two scripts share the
host's restic repo with the declarative backup module — they just
write a different `--tag`, so post-migration `restic forget --tag
preimpermanence` retires the migration history once `auto` backups
are trusted.

## Session log

After a substantive session (new subsystem, migration, architectural
decision), write `docs/sessions/YYYY-MM-DD-<slug>.md`. Do not edit
past session files.
