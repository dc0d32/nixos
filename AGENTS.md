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

# Format (the path argument is required: `nix fmt` with no path hangs,
# because formatter.nix binds a bare pkgs.nixpkgs-fmt which then blocks
# reading stdin)
nix fmt .

# Evaluate without building. PURE — there are no placeholder hosts, and
# it must stay that way: a real host runs `nixos-rebuild --flake
# github:...`, which evaluates purely. See "Placeholder hosts" below.
nix flake check

# Agent-side smoke build (no activation, no sudo)
nix build .#nixosConfigurations.pb-x1.config.system.build.toplevel
nix build .#homeConfigurations.'p@pb-x1'.activationPackage

# Backup wrappers (installed system-wide when flake.modules.nixos.backup
# is imported by the host bridge — see "Impermanence + backup" below):
sudo backup-snapshots                   # list snapshots in this host's repo
sudo backup-restore                     # restore latest (whole /persist)
sudo backup-restore --include /persist/home/p
./scripts/seed-from-host.sh --from pb-x1 --user p   # pull /persist/home/p
                                                     # from pb-x1's repo

# Auto-update wrappers (installed system-wide on every host that imports
# flake.lib.bundles.nixos.auto-deploy — i.e. all six NixOS hosts):
auto-update-status                      # policy, last run/success, next fire
sudo auto-update-now                    # run now, bypassing every gate
sudo systemctl stop auto-update.timer   # quiet, for a long refactor
```

## Auto-update

Every NixOS host polls ~hourly (`auto-update.timer`) and, when the gate
in `flake-modules/auto-update.nix` agrees — quiet window 02:00-09:00 or
>24h since the last success, on wall power, GitHub reachable — runs
`nixos-auto-upgrade.service` then `hm-auto-upgrade.service`, in that
order, via a `systemctl start --wait` sequencer. Never reboots, never
bumps `flake.lock`. Full write-up: `docs/auto-update.md`.

Things to know before touching it:

- The gate is an `ExecCondition=`, not an `ExecStartPre=`. A "not now"
  answer must leave the unit *inactive*, not *failed*, or hourly
  polling permanently reds out `systemctl status`.
- `autoUpdate.minIntervalHours` (default 6) is the rate limit and is
  load-bearing. The window is 7h wide and the timer polls hourly, and
  the staleness fallback keys on last-*success* — so without it a host
  awake overnight rebuilds ~7x/night and a host with a permanently
  failing step rebuilds every hour forever. It is stamped by the gate
  (on decide-to-proceed), not by the sequencer (on finish), so a run
  killed mid-switch still counts.
- Every unit in the chain carries `restartIfChanged = false` /
  `stopIfChanged = false` / `X-StopOnRemoval = false`. A
  `nixos-rebuild switch` restarts changed units mid-flight and will
  otherwise tear down the process performing the switch.
- Step order comes from `autoUpdate.steps` + `lib.mkOrder` (100 system,
  200 home-manager). Do NOT try to discover steps by testing
  `config.systemd.services ? <name>` inside the `mkIf` that defines
  `systemd.services.auto-update` — that is an infinite recursion.
- `auto-upgrade` and `hm-auto-upgrade` read options declared by
  `auto-update`, so the three are one bundle and importing either
  without the driver is an eval error.
- Unit scripts must not rely on session variables. A systemd service
  has no `SSL_CERT_FILE`, so curl has no CA bundle; test any generated
  unit script with `env -i PATH=/run/current-system/sw/bin <script>`.
- Wall power comes from `flake.lib.mkAcCheck`
  (`flake-modules/power-gate.nix`), shared with `backup.nix`. It scans
  sysfs for `Mains`/`USB*` supplies and, inside WSL, asks Windows for
  `PowerStatus.PowerLineStatus` over interop (recovering a
  `WSL_INTEROP` socket from `/run/WSL/*_interop`, since system services
  inherit none). Exit codes: 0 AC, 1 battery, 2 undeterminable —
  callers treat 2 as "proceed".

## Placeholder hosts

**There are currently none, and `nix flake check` / CI therefore run
PURE. Keep it that way.**

The mechanism still exists for bringing up a new host: stub
`hosts/<name>/hardware-configuration.nix` with an assertion gated on
`NIXOS_ALLOW_PLACEHOLDER=1`, and mark the bridge `placeholder = true;`
so the auto-generated `flake.checks.<system>.configurations:nixos:<name>`
entry is filtered out.

### The trap (learned the hard way, 2026-08-04)

`nix flake check` walks every entry in `nixosConfigurations` regardless
of which subset ends up in `checks` — built-in CLI behavior we can't
suppress — so a placeholder host makes a pure `nix flake check` fail.
The obvious fix was to run CI and the pre-push hook with
`NIXOS_ALLOW_PLACEHOLDER=1 ... --impure`. **That was actively harmful.**

A real host deploys with `nixos-rebuild --flake github:dc0d32/nixos#<h>`,
which evaluates **purely**, and under pure eval `builtins.getEnv` always
returns `""`. So the assertion can never pass on the real host, no matter
what is in its environment — while CI, running impure with the flag,
stayed green. `ah-1` imported the auto-deploy bundle and its
auto-upgrade aborted on *literally every run* for months, with a green
check on every push.

Rules that follow:

- **Never add `--impure` / `NIXOS_ALLOW_PLACEHOLDER=1` to
  `.github/workflows/flake-check.yml` or `smoke-build-hosts` in
  `flake-modules/dev-shell.nix`.** Those two gates must evaluate exactly
  what a host evaluates.
- **A placeholder host must not import
  `flake.lib.bundles.nixos.auto-deploy`.** Placeholder + auto-deploy is
  a statically guaranteed-broken combination.
- Smoke-build a placeholder by hand instead, and keep it out of the
  pushed set of deployable hosts until its
  `hardware-configuration.nix` is real:
  ```sh
  NIXOS_ALLOW_PLACEHOLDER=1 nix build --impure \
      .#nixosConfigurations.<name>.config.system.build.toplevel
  ```

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
moment it runs on bare-metal `pb-x1` / `pb-t480` / `m-pc`.

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
- **`custom/help`** — the waybar button that opens the discovery guide
  (below). Defined in `desktop-shell.nix` rather than contributed from
  `discovery.nix` because `programs.waybar.settings` is `types.anything`,
  whose merge does NOT concatenate lists — two modules both defining
  `modules-right` is an eval error, not a merge.

Lockscreen lives separately in `flake-modules/lockscreen.nix` (cross-
class because it carries a NixOS-side PAM service): `swaylock-effects`
with `security.pam.services.swaylock.fprintAuth = true`, so on
biometric hosts the fingerprint sensor unlocks alongside the password
prompt. No face unlock on the lockscreen — howdy + swaylock isn't a
thing anyone has wired (trade accepted at the quickshell-retreat
session: see `docs/sessions/`).

Each new HM file under the desktop-shell config needs `git add` before
rebuild — same flake-is-git-tracked caveat applies.

## Discovery (`guide` / `tip`)

`flake-modules/discovery.nix` exists because the kids had a large
toolset nobody had told them about — and because the maintainer forgets
his own operational surface between the quarterly times it fires. It is
in the **base** bundle, so every account on every host has it, including
headless WSL and macOS.

- `guide` — the cheat sheet. On a desktop it opens from `Mod+Slash`, the
  `?` button in waybar, or "Help & Tips" in fuzzel; everywhere it's just
  `guide`. Re-execs itself inside alacritty when it has no tty on stdin
  *and* stdout, so one command serves the launcher and the shell.
- `tip` — a rotating tip. The **content advances every hour**; the push
  surfaces are a mako notification at graphical login
  (`discovery-tip.service`) and a one-line zsh greeting in the first
  terminal opened each hour. Both share one stamp under
  `$XDG_STATE_HOME/discovery/`, so you get the tip from whichever
  surface you reach first, never both. There is deliberately **no
  hourly notification timer** — a popup every hour on a machine you sit
  in front of all day is a tax, not a feature. On a headless host the
  zsh greeting is the only push surface, which is why it is NOT gated
  on `hasNiri`.

Four invariants to preserve when editing it:

- **A bind appears in the guide iff it has a `hotkey-overlay.title`.**
  The title is simultaneously what niri's own `Mod+Shift+/` overlay
  shows and this module's curation marker, so the cheat sheet cannot
  drift from `flake-modules/niri/binds.nix`. Adding a bind worth
  knowing about = giving it a title, nothing else. Binds sharing a
  title collapse onto one row, so give the arrow-key and vim-key forms
  of one action the SAME title.
- **Tips are gated at RUNTIME, not eval time.** `probe` is a command
  that must be on PATH; `admin = true` additionally requires
  wheel/admin membership (`id -nG`). The maintenance wrappers
  (`backup-restore`, `auto-update-now`, `display-export`, …) are
  installed system-wide and therefore sit on the kids' PATH too, so a
  probe alone would leak them. Keep new tips gated the same way.
  GUI-only tips probe `niri` so they don't surface on WSL/macOS.
- **Many tips point at things that are NOT installed**, reached with
  `,` (comma, from nix-index-database) or `nix run nixpkgs#<attr>` —
  Blender, Godot, OpenSCAD, Sonic Pi, Krita, Step, Stellarium, ngspice,
  Maxima. Those tips probe `nix-locate`/`niri`, never the absent
  program. Check any new package name before writing it down:
  `nix eval nixpkgs#<attr>.name` and `nix-locate --minimal -w /bin/<cmd>`
  — several binaries (`step`, `godot`, `krita`, `octave`, `love`) are
  provided by more than one package, so `,` stops and asks and the tip
  should give the exact `nix run nixpkgs#…` form instead.
- **`hasNiri` comes from `options.programs ? niri`, the DECLARED-option
  tree** — never from `config`, which would recurse with this module's
  own bind definition. The desktop-only outputs are attached with
  `lib.optional` inside a `lib.mkMerge`, not `mkIf`, because on a
  headless config `programs.niri` is not a declared option at all and a
  `mkIf false` definition still trips the unknown-option check. For the
  same reason the module body is wrapped in an explicit
  `config = … ;`: the module system reads the top-level attrset's KEYS
  before it finishes building `options`, so a bare set whose key set
  depends on `options` is an infinite recursion.
- **Combine the two blocks with `lib.mkMerge`, never `//`.** Both define
  something under `programs.*` (`programs.zsh.initContent` and
  `programs.niri.settings.binds`), and `//` is a *shallow* update — it
  replaces the whole `programs` attribute and silently drops the zsh
  greeting. This shipped undetected for a whole phase because the
  headless configs, where the second block is empty, looked fine.
- **The rotation index and the "already shown" gate must stay the same
  number.** Both are `floor(epoch_seconds / 3600)`; if they diverge you
  get a tip that changes without the gate reopening, or vice versa.
  The index is `(bucket * 7919 + cksum(user)) % n` — 7919 is prime, so
  it's a full-cycle permutation (every tip appears once before any
  repeat) that still jumps between sections hour to hour.
- **The generated page must be written to a file ending in `.md`.**
  glow decides whether to render Markdown from the file *extension*; an
  extensionless `mktemp` path is passed through as plain text, which is
  how the notification surface ended up showing raw `# heading` source.
  Both `guide` and `tools` render through
  `flake.lib.mkMarkdownViewer` (`flake-modules/markdown-viewer.nix`),
  which also pins the style, width and pager so the page looks the same
  from a shell, the launcher and a notification.

Two further glow behaviours, both learned the hard way and both
documented in `flake-modules/markdown-viewer.nix`:

- **glow reads stdin in preference to its file argument** whenever
  stdin is not a terminal, so anything that consumes stdin before
  calling it must `exec </dev/tty` first or glow renders an empty
  document. (`stty size` needs the same thing to measure width.)
- **A glamour style file is used whole, not merged over a built-in.**
  Every element that should be styled has to appear in it. The repo
  ships its own style because every built-in theme with colour leaves
  the literal `##`/`###` markers on headings.

`md-view` also renders ```mermaid blocks via `mermaid-ascii`
(`overlays/mermaid-ascii.nix` — not in nixpkgs; the packaged
alternative, mermaid-cli, is a 2.1 GiB Chromium closure that emits
images alacritty cannot display). **It is deliberately conservative,
and must stay that way:** mermaid-ascii 1.4.0 exits non-zero on
diagram types it doesn't support, which is easy to handle, but for
unsupported node *shapes* inside a flowchart it exits **zero and
renders a wrong diagram** — `B{decision}` becomes a box literally
labelled `B{decision}` plus a phantom node `B`. Only `id[square]` is
understood. Blocks using `(round)`, `((circle))`, `{diamond}`,
`>flag]`, `[[sub]]` or `[(db)]` are therefore left as source; a
silently wrong diagram is worse than none.

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
   placeholder pattern (an assertion gated on
   `NIXOS_ALLOW_PLACEHOLDER=1`) until you can regenerate it on the
   live hardware. While it is a placeholder, do NOT give the host
   the auto-deploy bundle, and do NOT relax `nix flake check` to
   `--impure` to accommodate it — see "Placeholder hosts" above.
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

Before invoking nixos-anywhere it SSHes into the target and runs
a full pre-wipe on `disko.devices.disk.main.device` (derived from
the flake): `wipefs -af` + `sgdisk --zap-all` + `dd` first 16 MiB
to zero + `blockdev --flushbufs` + `partprobe` + `udevadm settle`.
The `blockdev --flushbufs` is the critical step — on a repave the
installer kernel caches the previous install's filesystem-type
detection per device, which survives mkfs and causes disko's
internal subvolume mount to dispatch to `vfat` and fail with
`Unknown parameter 'subvol'`. Flushing the device's page cache
forces the kernel to re-detect from the fresh superblock.

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
