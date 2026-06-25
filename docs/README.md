# docs/ — orientation

If you're returning to this repo after a long pause, read this
first. The repository top-level `README.md` is the user-facing
description; this file is the navigation index for the docs/
directory.

## Where things live

```
flake.nix                          inputs + flake-parts entry
flake-modules/                     dendritic feature modules
  hosts/<name>.nix                 host bridges (opt features in here)
  <feature>.nix                    each contributes flake.modules.{nixos,homeManager}.<feature>
hosts/<name>/                      per-host assets (hardware-config, audio presets, …)
overlays/                          custom overlays
scripts/
  install.sh                       nixos-anywhere wrapper for fresh installs
  init-backup.sh                   bootstrap restic backup on a host
  seed-from-host.sh                pull a user's home from another host's repo
  audio-discover.sh                emit an EasyEffects autoload entry
  biometrics-enroll.sh             one-shot fingerprint + face setup
docs/
  README.md                        this file
  runbooks/                        operator playbooks
  sessions/                        immutable agent session logs (history)
```

## Daily life

```sh
sudo nixos-rebuild switch --flake .#<host>      # NixOS
home-manager switch --flake .#'<user>@<host>'   # home-manager
nix fmt                                          # format every .nix
```

## Installing a fresh host

1. Add `flake-modules/hosts/<name>.nix` + stub
   `hosts/<name>/hardware-configuration.nix`.
2. Boot the target machine on the NixOS installer ISO with
   networking + root SSH.
3. From a checkout, run `./scripts/install.sh <name> <target-ip>`.
4. After it reboots: regenerate hardware-configuration.nix on the
   live kernel, commit, push.
5. If the host imports `flake.modules.nixos.backup`, run
   `sudo scripts/init-backup.sh` on it.
6. (Optional, when migrating user state from another host)
   `sudo scripts/seed-from-host.sh --from <other> --user <login>`.

## Architecture

- Dendritic flake on top of [flake-parts](https://flake.parts) +
  [import-tree](https://github.com/vic/import-tree). Every Nix
  file under `flake-modules/` is a top-level module, auto-imported.
- Each feature module contributes to
  `flake.modules.<class>.<feature>` for whichever class(es) it
  applies to (`nixos`, `homeManager`, or both).
- Hosts opt in to a feature by importing
  `config.flake.modules.<class>.<feature>` from their host bridge.
- Home Manager runs standalone (NOT wired into NixOS as a module),
  so the same HM modules work on bare-metal Linux, WSL, and a
  future macOS host.

The full design rationale lives in the docs/sessions/ archive —
the most recent entries are the freshest. Start with the latest
session whose title overlaps your concern.

## Runbooks

- [`truenas-restic.md`](runbooks/truenas-restic.md) — one-time
  NAS-side setup (user + sshd Match block + dir).
- [`extract-audio-presets-from-lenovo-driver.md`](runbooks/extract-audio-presets-from-lenovo-driver.md)
  — extracting EasyEffects presets from Lenovo's Windows audio
  driver.

## Hard rules

- HM stays standalone (no NixOS-side wiring).
- No secrets framework yet (no sops-nix/agenix).
- LF line endings only (enforced by `.gitattributes`).
- New files must be `git add`-ed before any flake build sees them.
- Substantial sessions get a `docs/sessions/YYYY-MM-DD-<slug>.md`
  note. Past session files are immutable.
