# Session: NixOS in WSL (incl. Windows on ARM) + aarch64 across platforms — 2026-04-21

## Change

Added first-class support for running this flake on NixOS inside WSL2,
including Windows on ARM, and confirmed the flake plumbing already handles
aarch64 on macOS, native Linux, and WSL.

### WSL

- Added flake input `nixos-wsl` → **`github:dc0d32/nixos-aarch64-wsl`**
  (publishes both x86_64-linux and aarch64-linux WSL rootfs tarballs so
  Windows on ARM works out of the box).
- New module `modules/nixos/wsl.nix`, gated on `variables.wsl.enable`:
  imports the nixos-wsl module, force-disables bootloader, DM (ly), niri,
  pipewire, hardware.graphics, xserver videoDrivers, NetworkManager,
  firewall, thermald, fwupd, powerManagement. Sets WSL user's shell to zsh.
- Host template `configuration.nix` now guards the explicit user declaration
  and bootloader on `lib.mkDefault (!isWsl)` so nixos-wsl's own user decl
  wins inside WSL.
- `modules/home/default.nix` gates the desktop home stack
  (niri/waybar/quickshell/idle/chrome) on `isLinux && !isWsl`.
- `apps/new-host.nix --wsl` flag: detects `uname -m`, flips
  `variables.wsl.enable = true`, turns off niri/waybar/quickshell/pipewire/
  ly/idle/chrome, sets `gpu.driver = "none"`, removes the
  `hardware-configuration.nix` placeholder.

### aarch64 everywhere

No changes needed — the flake was already arch-agnostic:

- `lib/forAllSystems` iterates `x86_64-linux aarch64-linux x86_64-darwin
  aarch64-darwin` for apps/devShells/packages/formatter.
- `lib.mkHost` and `lib.mkHome` both read `variables.system` directly, so
  any of those four systems just works.
- `mkHome` picks `/Users/${user}` on darwin and `/home/${user}` elsewhere
  via `lib.hasSuffix "darwin"`, so ARM macOS and ARM Linux both resolve
  correctly.
- `new-host` auto-detects aarch64 in `--mac` and `--wsl` paths. For native
  ARM Linux, the script still detects x86 vs arm via `uname -m` when run on
  that host (since it only overrides system when `--mac` or `--wsl`, a
  native ARM Linux host built on itself uses `x86_64-linux` by default;
  added a README note telling the user to hand-edit `variables.system` in
  that case — or I can add a `--linux-arm64` flag later if this becomes a
  common path).

### README architecture table

Added a table mapping each platform to its system string and the right
scaffold invocation, plus a note about aarch64 unfree-binary gaps (chrome,
slack, zoom don't publish aarch64-linux).

## Rationale for the WSL input choice

`dc0d32/nixos-aarch64-wsl` publishes WSL rootfs tarballs for both
x86_64-linux and aarch64-linux, so the same flake input covers Intel/AMD
Windows and Windows on ARM without fragmenting the module source.

## How to use

From inside the NixOS WSL distro (x86 or arm), after cloning:

```sh
nix run .#new-host -- "$(hostname)" --wsl
sudo nixos-rebuild switch --flake .#"$(hostname)"
# (from Windows) wsl --terminate <distro-name>
```

For native aarch64 Linux (i.e. real arm hardware, not WSL), scaffold normally
and hand-edit `variables.system = "aarch64-linux"` if the default of
`x86_64-linux` was written.

## Caveats

- **First rebuild requires WSL restart** (systemd / nativeSystemd picks up
  cleanly on the next launch).
- **nixos-wsl owns the default user**; host template skips declaring
  `users.users.${user}` when `wsl.enable` is true.
- **aarch64 unfree holes**: Chrome, Slack, Zoom, Teams, 1Password have no
  aarch64-linux package. They do exist on aarch64-darwin (macOS).
- **pipewire is off in WSL** — WSLg brings its own pulse tunnel. Don't
  re-enable.
- **GPU in WSL**: `gpu.driver = "none"`. WSLg/DirectX handles GPU itself.
  Don't try to wire `hardware.graphics` on.

## Files touched

New:
- `modules/nixos/wsl.nix`
- `docs/sessions/2026-04-21-wsl-support.md` (this file)

Updated:
- `flake.nix` — `nixos-wsl` input pointing at the fork.
- `modules/nixos/default.nix` — imports `./wsl.nix`.
- `modules/home/default.nix` — gates desktop stack on `!isWsl`.
- `hosts/_template/variables.nix` — `wsl` section.
- `hosts/_template/configuration.nix` — bootloader + user guarded by
  `!isWsl`.
- `apps/new-host.nix` — `--wsl` flag, aarch64 detection.
- `README.md` — WSL bootstrap section + architecture table.
