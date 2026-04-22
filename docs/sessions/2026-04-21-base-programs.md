# Session: base programs & GPU selector — 2026-04-21

## Scope

Filled out the first real batch of cross-platform programs + the GPU driver
selector asked for during initial host setup.

## What was added

### Cross-platform (home-manager, NixOS + macOS)

- **neovim** (`modules/home/editor/neovim.nix`) — full rewrite.
  - LSPs: nil (nix), lua_ls, pyright, rust-analyzer, gopls, ts_ls, bashls,
    jsonls, yamlls, html, cssls, marksman, taplo.
  - Treesitter with all grammars (+ textobjects).
  - nvim-cmp with LuaSnip, buffer/path sources.
  - Telescope (+ fzf native), gitsigns, fugitive, conform (auto-format on save
    via stylua/nixpkgs-fmt/black/prettierd), which-key, lualine, indent-blankline,
    autopairs, comment, surround.
  - Catppuccin Mocha theme wired to all plugins.
  - Keymaps: leader=Space. `<leader>f{f,g,b,h,r}` Telescope; `gd/gr/gi/K` LSP;
    `<leader>rn/ca` rename/code-action; `<esc>` clears search; window nav with
    `<C-hjkl>`.
  - Still uses `programs.neovim` (not nixvim) to keep config portable and
    human-readable; Lua lives in one `extraLuaConfig` block.
- **btop** (`modules/home/tools/btop.nix`).
- **build-deps** (`modules/home/tools/build-deps.nix`) — gcc, gnumake, cmake,
  pkg-config, autoconf, automake, libtool, python3, nodejs, unzip/zip/tar/xz,
  rsync, curl, wget, file, tree, jq, yq-go, which, dig, nmap, iperf3.
- **Google Chrome** (`modules/home/apps/chrome.nix`) — linux only, unfree;
  sets `NIXOS_OZONE_WL=1` for Wayland. Gated on `variables.apps.chrome.enable`.
  On macOS the module no-ops (Chrome isn't in nixpkgs-darwin).

### NixOS-only

- **GPU selector** (`modules/nixos/gpu.nix`) — reads
  `variables.gpu.driver ∈ {"intel","amd","nvidia","none"}` and wires:
  - `hardware.graphics.enable/enable32Bit` (new nixpkgs name, replaces the
    deprecated `hardware.opengl.*`).
  - Intel: `intel-media-driver` + legacy `vaapiIntel` fallback.
  - AMD: `amdgpu` Xorg driver; RADV is automatic via mesa.
  - NVIDIA: proprietary `nvidia` driver (stable branch), modesetting on,
    `nvidia-drm.modeset=1` kernel param. `hardware.nvidia.open = false`
    (flip when you want the open kernel module).
  - None: nothing touched (VMs, headless).
  - Emits a `warnings` entry if the driver string is unknown.
- **system-utils** (`modules/nixos/system-utils.nix`) — `util-linux` (gives
  fdisk/cfdisk/lsblk), parted, gptfdisk, dosfstools, e2fsprogs, ntfs3g,
  exfatprogs, cryptsetup, hdparm, smartmontools, nvme-cli, gcc/gnumake/binutils/
  pkg-config, file/tree/ripgrep/fd, curl/wget/rsync/openssh/tmux/htop.
  `nmtui` ships inside NetworkManager which is already enabled in
  `modules/nixos/networking.nix`.
- **power / autosleep** (`modules/nixos/power.nix`) — logind handles lid close
  = suspend (except when docked on external power), power button short-press
  = suspend, long-press = poweroff. `fwupd` + `thermald` on. logind's own
  `IdleAction=ignore` so the user-level swayidle owns the timing.
- **ly login manager** (`modules/nixos/desktop/login-ly.nix`) — gated on
  `variables.login.ly.enable`. Force-disables GDM/SDDM/LightDM so there's no
  accidental conflict. Niri's session file is picked up automatically.

### User-level idle

- **swayidle** (`modules/home/desktop/idle.nix`) — default timings:
  - 5 min → swaylock (Catppuccin crust background).
  - 7 min → `niri msg action power-off-monitors` (resume restores).
  - 15 min → `systemctl suspend`.
  - Also locks before-sleep and on explicit `loginctl lock-session`.
  - All thresholds configurable via `variables.idle.{lockAfter,dpmsAfter,suspendAfter}`.

## Feature flags (hosts/_template/variables.nix)

```nix
gpu.driver       = "intel";           # intel | amd | nvidia | none
login.ly.enable  = true;
idle = { enable = true; lockAfter = 300; dpmsAfter = 420; suspendAfter = 900; };
apps.chrome.enable = true;
git = { name = "CHANGEME"; email = "CHANGEME@example.com"; };
```

## Decisions locked in

- **neovim via `programs.neovim` + Lua, not nixvim.** Keeps the config
  portable to any nvim install; plugins pinned through nixpkgs but the Lua is
  the same config you'd have on a non-Nix machine.
- **LSP setup is lspconfig + autocmd**, not `vim.lsp.config/enable` (nvim 0.11
  native API). lspconfig is still the easiest path for cross-version support;
  switch when 0.11 is the floor.
- **Auto-format on save** via `conform.nvim` is on. Disable per-host by adding
  `require("conform").setup({ format_on_save = false })` in the user's
  home.nix `programs.neovim.extraLuaConfig = lib.mkAfter "..."`.
- **ly** chosen as login manager over greetd/tuigreet/gdm. Rationale: tiny,
  no Qt/GTK, `services.displayManager.ly` is a one-liner on NixOS.
- **Power management is split**: logind (system-level lid/power-key/suspend)
  + swayidle (user-level DPMS/lock/suspend timers). This avoids double-firing
  suspend and keeps idle timings user-configurable.
- **Chrome is linux-only.** Mac-scope modules skip it; on macOS the user
  installs Chrome from google.com or `brew install --cask google-chrome`.
- **build-deps split between user and system.** Compilers exist at both
  scopes: system (`system-utils`) for out-of-tree kernel modules / root
  builds; user (`tools/build-deps`) for day-to-day dev. Overlap is fine —
  same store paths, no duplication.

## Files added / changed

New:
- `modules/home/tools/btop.nix`
- `modules/home/tools/build-deps.nix`
- `modules/home/apps/chrome.nix`
- `modules/home/desktop/idle.nix`
- `modules/nixos/gpu.nix`
- `modules/nixos/system-utils.nix`
- `modules/nixos/power.nix`
- `modules/nixos/desktop/login-ly.nix`

Rewritten:
- `modules/home/editor/neovim.nix` — now a full IDE config.

Updated imports / flags:
- `modules/home/default.nix`
- `modules/nixos/default.nix`
- `hosts/_template/variables.nix`
- `README.md`

## Known caveats

- **ly + Wayland sessions**: ly reads `.desktop` files from
  `/run/current-system/sw/share/wayland-sessions`. The niri-flake module
  installs one automatically. If you see "no sessions" in ly, confirm
  `ls /run/current-system/sw/share/wayland-sessions` has `niri.desktop`.
- **NVIDIA + niri** is still rough. If you use nvidia, expect to tweak
  kernel/DRM params. `hardware.nvidia.modesetting.enable` + kernel param
  `nvidia-drm.modeset=1` are the bare minimum. Open-kernel module (`open =
  true`) is required on Turing+ for the smoothest wayland experience; we
  left it false because it breaks on older cards.
- **swayidle suspend** requires logind's suspend target to work, which
  requires the user be in seat0. On NixOS with default users this is fine.
- **home-manager services.swayidle** already wires the systemd user unit.
  No manual `systemctl --user enable swayidle` required after HM switch.
- **nvim-treesitter.withAllGrammars** is a big closure (~hundreds of MB of
  grammars). If it's too heavy, swap to
  `nvim-treesitter.withPlugins (p: with p; [ nix lua python rust go tsx ... ])`.

## TODO / next

- Optional: swaylock replacement with PAM (the quickshell lock is a stub; the
  idle module uses real swaylock so that one authenticates fine).
- Optional: add `greetd` + `tuigreet` as an alternative login manager module
  behind the same `variables.login.*` namespace.
- Optional: per-host monitor layout wiring from `variables.monitors` into
  the niri home module.
