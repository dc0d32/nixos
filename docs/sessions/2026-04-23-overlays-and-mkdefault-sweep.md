# Session: Overlays subsystem + `mkDefault` sweep + nixpkgs naming drift — 2026-04-23

## Context

First bare-metal (x86_64 laptop) install of the flake surfaced a wave of
issues on top of the still-green WSL path. Fixing them in sequence produced
three related outcomes worth recording:

1. A proper overlays subsystem for out-of-tree package overrides.
2. A repo-wide convention that shared base modules set policy options with
   `lib.mkDefault` so WSL/host/upstream plain values win without ceremony.
3. A round of nixpkgs attribute/option renames we were still running on the
   old names for.

All three are now codified in `CLAUDE.md`.

## Overlays

### Shape

```
overlays/
  default.nix            # list-valued: [ (import ./foo.nix) (import ./bar.nix) ... ]
  nvim-treesitter-pin.nix
```

`default.nix` returns a **list** of overlay functions. Consumers use it
directly without wrapping:

- `lib/default.nix`: `overlays = import ../overlays;` (threaded through
  `mkHome`'s `pkgs` instance).
- `modules/nixos/nix-settings.nix`: `nixpkgs.overlays = import ../../overlays;`.

### First overlay: `nvim-treesitter-pin.nix`

nvim-treesitter `main` bumped its required tree-sitter CLI to **0.26.1** in
commit `5465196` (2026-01-29). Current `nixos-unstable` still ships
`tree-sitter` **0.25.10**, so `:checkhealth nvim-treesitter` hard-fails even
though grammars and highlighting work fine.

The overlay pins `vimPlugins.nvim-treesitter` to commit
`f8bbc3177d929dc86e272c41cc15219f0a7aa1ac` — the parent of the CLI bump and
the last main-branch rev that accepted 0.25. nixpkgs' `.withAllGrammars`
passthru threads through `overrideAttrs`, so consumers using
`nvim-treesitter.withAllGrammars` pick up the pinned source automatically;
no touchpoints in `modules/home/editor/neovim.nix` beyond restoring the
pre-pin form.

**Retirement condition** (also captured in the overlay file): delete once
`nix eval --raw nixpkgs#tree-sitter.version` reports ≥ 0.26.1.

### Convention (now in CLAUDE.md)

Every overlay file MUST carry:
1. A comment explaining *why* the override exists.
2. A retirement condition — the trigger that says it's safe to delete.

Without (2), overlays accumulate forever and nobody remembers which ones are
still needed. Prefer overlays over in-module `overrideAttrs` / `let`-bound
replacements so every override is centralized and greppable.

## `mkDefault` sweep

### Trigger

On the x86_64 laptop, `nixos-rebuild switch` failed with a parade of
"conflicting definitions" errors: `networking.firewall.enable`,
`powerManagement.enable`, `users.defaultUserShell`, and a handful of others.
Each was a base module of ours setting a plain value that clashed with a
plain value from either the upstream WSL fork (`github:dc0d32/nixos-aarch64-wsl/wsl.nix`)
or a nixpkgs base module (e.g. `programs/bash/bash.nix`).

### Fix

Shared base modules now set policy options with `lib.mkDefault` (priority
1000) so plain values (priority 100) from any downstream module win cleanly.
Converted:

| File | Options converted |
|------|-------------------|
| `modules/nixos/networking.nix` | `networkmanager.enable`, `firewall.enable` |
| `modules/nixos/power.nix` | `powerManagement.enable`, `thermald.enable`, `fwupd.enable` |
| `modules/nixos/gpu.nix` | `hardware.graphics.enable`, `enable32Bit`, `services.xserver.videoDrivers` |
| `modules/nixos/users.nix` | `programs.zsh.enable` (defaultUserShell kept *plain* — see below) |
| `modules/nixos/locale.nix` | `time.timeZone`, `i18n.defaultLocale` |
| `modules/nixos/nix-settings.nix` | scalars in `nix.settings`, `nix.gc`, `allowUnfree`, `allowAliases` |

### Exception: `users.defaultUserShell`

`pkgs.bash` (the nixpkgs module) sets `users.defaultUserShell = mkDefault
pkgs.bashInteractive`. Setting ours as `mkDefault pkgs.zsh` collides at
equal priority. We use a **plain value** `users.defaultUserShell = pkgs.zsh;`
in `modules/nixos/users.nix` — beats nixpkgs' `mkDefault` and
`wsl.nix`'s `mkForce pkgs.zsh` still beats us inside WSL.

### Convention (now in CLAUDE.md)

> In shared base modules (`modules/nixos/*.nix`, `modules/home/*.nix`), set
> policy options with `lib.mkDefault` so hosts and the upstream WSL fork can
> override them with plain assignments without triggering "conflicting
> definitions" errors. Reserve `mkForce` for modules that genuinely need to
> override a downstream plain value (e.g. `wsl.nix` belt-and-suspenders).

### Host cleanup

Redundant plain-value assignments of `time.timeZone` and `i18n.defaultLocale`
removed from `hosts/wsl-arm/configuration.nix` and
`hosts/_template/configuration.nix` — they're now sourced solely from
`modules/nixos/locale.nix`. `networking.hostName` and `console.keyMap` stay
host-scoped.

## `imports`-inside-`mkIf` bug sweep

Three modules had:

```nix
lib.mkIf cond {
  imports = [ ... ];
  # ...options...
}
```

`imports` is resolved *before* config evaluation and can't live inside a
mkIf-wrapped attrset. The fix shape is:

```nix
{
  imports = lib.optionals cond [ ... ];
  config = lib.mkIf cond { ... };
}
```

Fixed in:
- `modules/nixos/wsl.nix`
- `modules/nixos/desktop/niri.nix`
- `modules/home/desktop/niri.nix`

The WSL one was the hot bug (error message pointed at it); the two niri ones
were latent because desktop home/NixOS gating kept them from loading on the
WSL host.

## Nixpkgs naming drift

Our config had `nixpkgs.config.allowAliases = false` (set earlier to silence
the recurring `nvim-treesitter-legacy` deprecation warning), which meant
renamed attributes and moved options fail hard instead of silently
redirecting. The first bare-metal rebuild exposed a bunch at once:

| File | Old → New |
|------|-----------|
| `modules/nixos/desktop/login-ly.nix` | `services.displayManager.lightdm.enable` → `services.xserver.displayManager.lightdm.enable` (gdm/sddm did move to the new namespace; lightdm did not) |
| `modules/nixos/fonts.nix` | `noto-fonts-emoji` → `noto-fonts-color-emoji`; `nerdfonts.override { fonts = [ ... ]; }` → individual `nerd-fonts.<name>` attrs |
| `modules/nixos/gpu.nix` | Dropped `vaapiIntel`, `vaapiVdpau`, `libvdpau-va-gl`; kept `intel-media-driver`; added `LIBVA_DRIVER_NAME=iHD` per current wiki guidance |
| `modules/nixos/power.nix` | All seven logind top-level options (`lidSwitch`, `lidSwitchDocked`, `lidSwitchExternalPower`, `powerKey`, `powerKeyLongPress`, `suspendKey`, `hibernateKey`) + `extraConfig` → single `services.logind.settings.Login` block with systemd names (`HandleLidSwitch`, etc.) |

### Font choice

Replaced JetBrainsMono with **Rec Mono Casual** as the monospace default.
`pkgs.nerd-fonts.recursive-mono` ships all four variants (Casual, Linear,
Duotone, Semicasual); fontconfig picks via family name.

`fontconfig.defaultFonts.monospace = [ "RecMonoCasual Nerd Font" "JetBrainsMono Nerd Font" ]`
— Rec Mono preferred, JetBrainsMono as fallback.
`modules/home/terminal/alacritty.nix` explicitly sets
`font.normal.family = "RecMonoCasual Nerd Font"`.

## Laptop boot failure (debugging session, no code change)

After the rebuild finally evaluated and built cleanly, boot entries were not
appearing in the systemd-boot menu despite `nixos-rebuild switch` succeeding
and `list-generations` showing the new generation. Root cause: an older
system generation's toplevel had a dangling `kernel` symlink — probably from
a half-completed `switch` during one of the earlier failures. Every time
`systemd-boot-builder` ran, it tried to write an entry for *every* generation
in `/nix/var/nix/profiles/` and aborted on the first broken one. The hash in
the error message was the broken generation's, not the current one.

Fix:

```
sudo nix-env --delete-generations old -p /nix/var/nix/profiles/system
sudo nix-collect-garbage -d
sudo nixos-rebuild switch --flake .#<host> --install-bootloader
```

Worth knowing in general: the hash in a systemd-boot install error does not
have to be the current toplevel's. Compare against `nix eval --raw
.#nixosConfigurations.<host>.config.system.build.toplevel`; if they differ,
the culprit is another generation.

## Files touched

- `CLAUDE.md` — overlay and `mkDefault` conventions added.
- `overlays/default.nix` — now list-valued with convention comment.
- `overlays/nvim-treesitter-pin.nix` — new.
- `lib/default.nix` — `overlays = import ../overlays;`.
- `modules/nixos/nix-settings.nix` — `nixpkgs.overlays = import ../../overlays;`, `mkDefault` sweep.
- `modules/nixos/wsl.nix` — `imports`-outside-mkIf fix; `mkForce` on `users.defaultUserShell`; comment cleanup.
- `modules/nixos/networking.nix`, `power.nix`, `gpu.nix`, `users.nix`, `locale.nix` — `mkDefault` sweep; inline attribute/option renames (power.nix logind, gpu.nix Intel).
- `modules/nixos/fonts.nix` — noto-fonts-emoji/nerd-fonts rename; Rec Mono Casual.
- `modules/nixos/desktop/login-ly.nix` — lightdm path fix.
- `modules/nixos/desktop/niri.nix`, `modules/home/desktop/niri.nix` — `imports`-outside-mkIf fix.
- `modules/home/editor/neovim.nix` — reverted the in-module pinned-ts let-block; now back to plain `nvim-treesitter.withAllGrammars` with a comment pointing at the overlay.
- `modules/home/terminal/alacritty.nix` — Rec Mono Casual.
- `modules/home/tools/build-deps.nix` — `tree-sitter` CLI in `home.packages` (moved from neovim's `extraPackages` so checkhealth finds it on PATH in the same place as `tar`/`curl`).
- `hosts/wsl-arm/configuration.nix`, `hosts/_template/configuration.nix` — drop redundant `time.timeZone` / `i18n.defaultLocale`.
- `.gitignore` — ignore `.claude/settings.local.json`.

## Open threads

- Tree-sitter pin hash still `lib.fakeHash` — first rebuild on a host that
  actually builds the plugin will print the real SRI hash to paste in.
- Laptop was temporarily using the `wsl-arm` flake output (its `variables.nix`
  had `wsl.enable = true`), which is why `wsl-setup.service` was firing and
  why the bootloader was being gated off by `!isWsl`. Proper laptop host
  should be scaffolded via `nix run .#new-host -- <hostname>`; keeping the
  `wsl-arm` output reusable is not an intended path.
