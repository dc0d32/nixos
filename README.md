# dc0d32 / nixos

Personal declarative config for NixOS (full system) and home-manager.
Configured hosts:

- `pb-x1` — primary dev laptop (Lenovo X1 Yoga gen 7, x86_64-linux).
- `wsl` — NixOS inside WSL2 on x86_64 Windows.
- `wsl-arm` — NixOS inside WSL2 on Windows on ARM (aarch64-linux).

More machines (additional laptops + servers) will be added under
`flake-modules/hosts/<name>.nix`.

## Layout

```
flake.nix                     inputs + flake-parts substrate
flake-modules/                dendritic feature modules (one per concern)
  hosts/pb-x1.nix             host bridge: primary laptop
  hosts/pb-mb.nix             host bridge: MacBook Air M4 (standalone HM only)
  hosts/wsl.nix               host bridge: both WSL configurations
  <feature>.nix               each contributes flake.modules.{nixos,homeManager}.<feature>
  FusionLike/                 FreeCAD auto-startup mod (Init.py + InitGui.py)
hosts/pb-x1/                  hardware-configuration.nix + audio presets/IRS dirs
overlays/                     custom overlays (each documents why and when to delete)
packages/                     custom package definitions
docs/                         design notes and AI session history (see docs/sessions/)
```

## Architecture

This flake follows the **dendritic pattern** (mightyiam/dendritic):

- Every Nix file under `flake-modules/` is a top-level
  [flake-parts](https://flake.parts) module, auto-imported via
  [import-tree](https://github.com/vic/import-tree).
- Each feature module contributes to `flake.modules.<class>.<feature>`
  for whichever class(es) it applies to (`nixos`, `homeManager`, or
  both as a cross-class module).
- Hosts opt in to a feature by including
  `config.flake.modules.<class>.<feature>` in their `imports = [ … ]`
  list. **Importing IS enabling** — no per-feature `enable` gate.
- Cross-module data flows through top-level `options.<ns>` declared by
  the feature module that owns the data, set on the host bridge file.
  See `flake-modules/battery.nix` for a worked example.
- Per-NixOS-config values (hostname, primary user, etc.) are set
  inside each host bridge's `configurations.nixos.<name>.module = { … }`
  block, NOT at the flake-parts level. See `flake-modules/users.nix`
  for the `users.primary` pattern.

Design choices:

- **Home Manager is standalone** (not wired into NixOS as a module).
- **Everything declarative**: no separate dotfiles repo. User configs
  live under `flake-modules/<feature>.nix`.
- **Compositor**: niri. **Shell**: zsh. **Editor**: neovim.
  **Terminal**: alacritty.
- **No secrets module yet** — added later if needed (sops-nix or agenix).

## Day-to-day

```sh
# Rebuild NixOS on the primary laptop
sudo nixos-rebuild switch --flake .#pb-x1

# Rebuild user environment on the primary laptop
home-manager switch --flake .#'p@pb-x1'

# Inside WSL (x86_64)
sudo nixos-rebuild switch --flake .#wsl
home-manager switch --flake .#'p@wsl'

# Inside WSL (Windows on ARM)
sudo nixos-rebuild switch --flake .#wsl-arm
home-manager switch --flake .#'p@wsl-arm'

# On the MacBook Air (macOS — userland only, no nixos-rebuild)
home-manager switch --flake .#'p@pb-mb'

# Generate + push the native-Windows dotfiles (run inside WSL; builds
# on demand, independent of home-manager switch). See "Native Windows".
hm_win

# Update all inputs
nix flake update

# Evaluate everything without building
nix flake check

# Format all nix files
nix fmt
```

## Adding a feature

1. Create `flake-modules/<feature>.nix` that contributes to
   `flake.modules.<class>.<feature>`. Pure-leaf modules can use
   `flake.modules.<class>.<feature> = { … };` directly. Modules that
   need host-tunable data declare `options.<ns>` plus
   `config.flake.modules.<class>.<feature> = let cfg = config.<ns>; in { … };`.
2. Add `config.flake.modules.<class>.<feature>` to the appropriate
   `imports = [ … ]` list inside the host bridges that should enable
   the feature (e.g. `flake-modules/hosts/pb-x1.nix`).
3. If the feature needs host-specific values, set them as top-level
   option values in the host bridge.
4. `git add` the new file (the flake build only sees git-tracked files).
5. Verify with `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
   or `nix build .#homeConfigurations.'<user>@<host>'.activationPackage`.

Each module begins with a short header documenting (1) why it exists
and (2) the condition under which it can be deleted.

## Adding a new host

1. Create `flake-modules/hosts/<name>.nix` modeled after
   `pb-x1.nix` (bare-metal laptop) or `wsl.nix` (headless / WSL).
   For physical hosts and VMs, import disko: pull in
   `config.flake.modules.nixos.disko` plus one of
   `config.flake.lib.diskoLayouts.bare-metal` (BIOS+UEFI, btrfs
   subvols + optional swap partition) or `.vm` (UEFI-only ext4).
2. Stub `hosts/<name>/hardware-configuration.nix` with the
   placeholder pattern used by `pb-t480` and `m-pc` until you can
   regenerate it on the live hardware.
3. Pick which feature modules to import; set their option values.
4. Set `users.primary = "<your-user>";` inside the per-config
   `module` block (declared by `flake-modules/users.nix`).
5. `git add` every new file (flake builds only see git-tracked
   files).

## macOS (userland-only)

The MacBook Air host (`pb-mb`) is **standalone home-manager only** —
there is no `nixosConfiguration` and **nix-darwin is not used**. macOS
stays the base OS; this flake only ever writes inside `$HOME`. That
keeps the whole thing reversible to vanilla macOS with no repave.

Bootstrap on a fresh Mac:

```sh
# 1. Install Nix (Determinate Systems installer — Apple-Silicon-aware,
#    creates the /nix APFS volume and enables flakes out of the box).
curl --proto '=https' --tlsv1.2 -sSf -L \
  https://install.determinate.systems/nix | sh -s -- install

# 2. Clone this flake and activate the user environment.
git clone https://github.com/dc0d32/nixos ~/nixos && cd ~/nixos
nix run home-manager/master -- switch --flake .#'p@pb-mb'

# 3. Thereafter, routine updates:
home-manager switch --flake .#'p@pb-mb'
```

Going back to stock macOS (no repave):

```sh
home-manager uninstall          # removes ~/.config/home-manager state,
                                # profile, and dotfile symlinks
sudo /nix/nix-installer uninstall   # removes /nix, _nixbld* users,
                                # and the /etc/{zshrc,bashrc} hooks
rm -rf ~/Library/Fonts/HomeManager  # the flake-managed font dir
```

`pb-mb` imports the cross-platform `dev` bundle plus `alacritty`,
`vscode`, and `fonts` (which, on darwin, mirrors the face set into
`~/Library/Fonts/HomeManager/` for Core Text). Linux-only features
(Wayland desktop, audio, power/battery, biometrics, impermanence,
backup) are absent. `aarch64-darwin` is intentionally **not** added to
`flake-modules/systems.nix`: the closure can only be built on the Mac
itself, and `homeConfigurations` is published regardless, so leaving it
out keeps `nix flake check` from carrying an un-buildable check on the
Linux hosts.

## Native Windows (`hm_win`)

Nix can't run natively on Windows, so there's no home-manager there. But
the *dotfiles* are just text, so `flake-modules/windows/` **generates**
the native-Windows config from Nix (a PowerShell `$PROFILE`, a shared
`starship.toml`, a Scoop install script, and a `winget` configuration)
and a WSL-side command **`hm_win`** copies them into the Windows profile
(`/mnt/c/Users/<you>/…`). It copies rather than symlinks (NTFS can't
follow WSL links), backing up anything it replaces.

Workflow:

```sh
# inside WSL — builds the bundle from your ~/nixos checkout and pushes it:
hm_win
```

Generation is gated behind `hm_win` alone: the artifacts are a separate
flake package (`packages.<system>.windows-dotfiles`), and `hm_win` is a
thin wrapper that `nix build`s it on demand. A plain `home-manager
switch` (`hm`/`nr`) installs only the small wrapper and never builds or
regenerates any Windows content.

`hm_win` finds the Windows profile by querying the Windows interop at
runtime (`pwsh`/`cmd` — a plain shell query on your machine, so no
`--impure`), which adapts to the real account name and an
OneDrive-redirected Documents folder. If the interop isn't reachable it
errors out asking you to set `HM_WIN_USER=<your-windows-username>`.

Then, once, in PowerShell on Windows: run the generated
`~\.config\nixwin\scoop-install.ps1` (installs the CLI toolkit + a Nerd
Font via Scoop; `winget configure ~\.config\nixwin\winget.configuration.yaml`
handles PowerShell 7 / Windows Terminal / Azure CLI), then restart the
terminal.

What's shared from one definition: the **starship prompt**
(`flake.lib.starshipSettings`, also used by zsh), the **`terminal-help.md`**
guide (the `tools` command renders it on both sides), and the alias set.
`hm_win` also sets the Windows Terminal default **font** (RecMono Nerd
Font) via a non-destructive `jq` merge, leaving all keybindings at their
defaults. `hm_win` is imported only on the WSL hosts (it needs `/mnt/c`).
Tools with no native Windows build (`lnav`, `tmux`) are omitted.

## Installing on real hardware

This flake uses [`nixos-anywhere`](https://github.com/nix-community/nixos-anywhere)
for fresh installs. Boot the official NixOS installer ISO (or any
kexec image) on the target machine, bring networking up, log in
as `root`, and from a machine that already has this flake checked
out run:

```sh
./scripts/install.sh <hostname> <target-ip>
```

`install.sh` is a thin wrapper around `nixos-anywhere --flake
.#<hostname> --target-host root@<target-ip>`. It:

1. SSHes to the target and pre-wipes the primary disk
   (`wipefs` + `sgdisk --zap-all` + zero first 16 MiB +
   `blockdev --flushbufs` + `partprobe` + `udevadm settle`). The
   `blockdev --flushbufs` step matters: on a repave the installer
   kernel caches per-device filesystem-type detection from the
   previous install, which survives mkfs and breaks disko's
   subvolume-creation mount with `vfat: Unknown parameter
   'subvol'`. Flushing the page cache forces fresh re-detection.
2. If `hosts/<hostname>/hardware-configuration.nix` is still the
   placeholder, hands nixos-anywhere `--generate-hardware-config
   nixos-generate-config <path>` so it regenerates the file on the real
   hardware (with `--no-filesystems`, since disko owns the filesystems)
   *before* building — without this a fresh host can't build because the
   placeholder assertion aborts `system.build.toplevel`. Skipped once
   the file is real, so re-paves respect the committed config.
3. Builds the host's disko script + system closure.
4. Partitions + formats the target's disks per `disko.devices`.
5. Copies the closure to the target and runs `nixos-install`.
6. Reboots into the new system.

Pre-flight on bare metal:

- **Secure Boot must be OFF in UEFI.** NixOS' default kernel isn't
  shim-signed.
- **For Microsoft Surface devices** import
  `flake.modules.nixos.surface` in the host bridge — touchscreen,
  pen, suspend, audio, Wi-Fi quirks need it.
- **Networking must come up on the installer.** USB-ethernet is
  simplest; for WiFi use `iwctl` / `nmtui` from the installer
  shell. `nixos-anywhere` ships the closure to the target over
  SSH; if the network is down it fails before any disk is touched.

After first boot:

1. Commit the regenerated hardware-configuration.nix. For a host that
   was installed from the placeholder, `install.sh` already had
   nixos-anywhere regenerate `hosts/<hostname>/hardware-configuration.nix`
   on the real hardware (via `--generate-hardware-config`), so it is
   sitting dirty in your working tree — just review and
   `git add` + commit it. (To regenerate manually later:
   `sudo nixos-generate-config --no-filesystems --show-hardware-config
   > hosts/<hostname>/hardware-configuration.nix`.)
2. Bootstrap restic backup (if the host imports
   `flake.modules.nixos.backup`):
   `./scripts/init-backup.sh`. Prompts for the NAS account
   password and the repo password (from your password manager).
3. (Optional, only when porting state from another host)
   `./scripts/seed-from-host.sh --from <other-host> --user <login>`
   pulls `/persist/home/<login>` from the other host's repo.

## Module conventions

- Comment header on every module: (1) why it exists, (2) retirement
  condition.
- `lib.mkDefault` for policy values that hosts may want to override
  without `mkForce`.
- Top-level options live next to the module that owns them; consumed
  by reading `config.<ns>` inside the module that contributes the
  config.
- Per-NixOS-config values (hostname, primary user, system tuple, …)
  are set inside `configurations.nixos.<name>.module`, NOT at the
  flake-parts level.

## One-time hardware setup (hosts importing `biometrics`)

These steps are required once after the first `nixos-rebuild switch`
on any laptop importing `flake-modules/biometrics.nix` (currently
pb-x1 and pb-t480). Other hosts (WSL, headless servers) don't need
any of this.

### Quick path: `biometrics-enroll`

The interactive helper walks you through both fingerprint and face
enrollment. Run from a Wayland terminal (not a TTY) so the IR
emitter calibration preview can open:

```sh
biometrics-enroll          # all of it: fingerprints, then face
biometrics-enroll fingerprint
biometrics-enroll face
biometrics-enroll verify   # test both after enrollment
```

The script invokes `sudo` internally only for the steps that need
it (IR emitter calibration, howdy).

### Manual path

If you want to drive it yourself instead of via `biometrics-enroll`:

```sh
# Fingerprints — repeat for each finger you want.
fprintd-enroll
# or enroll a specific finger:
fprintd-enroll -f right-index-finger "$USER"
fprintd-verify

# IR face: one-time calibration, then enroll a model.
# Must run from a Wayland session (not a TTY) so the preview opens.
sudo -E linux-enable-ir-emitter configure
sudo howdy -U "$USER" add
sudo howdy -U "$USER" test
```

After both are set up, the auth order at login/lock/sudo is:
**face → fingerprint → password** (any one is sufficient).

## Repository conventions

- Nix code is formatted with `nixpkgs-fmt` (see
  `flake-modules/formatter.nix`).
- Commit messages: short imperative subject; body for the "why".
- Line endings stay LF (enforced by `.gitattributes`).
- Substantial sessions get a note in `docs/sessions/YYYY-MM-DD-<slug>.md`.
- Past session notes are immutable.
