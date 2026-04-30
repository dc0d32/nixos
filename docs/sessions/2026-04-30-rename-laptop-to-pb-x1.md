# 2026-04-30 — rename host `laptop` → `pb-x1`

The primary laptop's host name was `laptop`, a generic placeholder
chosen when only one host existed. With more laptops and servers
planned, renamed to `pb-x1` (initials + "X1 Yoga" model).

## What changed

- `git mv flake-modules/hosts/laptop.nix → flake-modules/hosts/pb-x1.nix`.
- `git mv hosts/laptop → hosts/pb-x1` (the host-asset directory:
  `hardware-configuration.nix`, `audio-presets/`, `audio-irs/`).
- Inside `flake-modules/hosts/pb-x1.nix`:
  - `hostName = "laptop"` → `"pb-x1"`. This automatically renames
    the `nixosConfigurations.<name>`, `homeConfigurations.<user>@<name>`,
    and `networking.hostName` it produces.
  - Updated the path references for the audio assets and
    hardware-configuration.nix from `../../hosts/laptop/...` to
    `../../hosts/pb-x1/...`.
  - Updated the file's header comment to describe pb-x1 (Lenovo X1
    Yoga gen 7) and explain the naming.
- `README.md`: rewritten host section to enumerate `pb-x1`, `wsl`,
  `wsl-arm`. Updated all command examples. Added note about future
  additional laptops + servers.
- `AGENTS.md`, `CLAUDE.md`: updated all `.#laptop` / `.#'p@laptop'`
  command examples to `.#pb-x1` / `.#'p@pb-x1'`. Updated the
  `hosts/laptop/` path references in the EasyEffects example.

## Verification

- `.#nixosConfigurations.pb-x1.config.system.build.toplevel`
  → `cbxci9lv0kg7xgkk2pvl1xqyplzn3r8w-nixos-system-pb-x1-…`
  (new hash, expected: `networking.hostName` and the system name
  string both changed).
- `.#homeConfigurations.'p@pb-x1'.activationPackage`
  → `ds56glplhvl53m19jwfzymairxyg1780-home-manager-generation`
  (byte-identical to the previous `p@laptop` HM closure — confirms
  HM doesn't depend on the hostname).
- `.#nixosConfigurations.wsl.config.system.build.toplevel`
  → `f8pc9csn7cp1qzcx753cp80ny7wjb141` (unchanged, byte-identical).
- `.#homeConfigurations.'p@wsl'.activationPackage`
  → `pr3b9gcyqdfb3ww1hcj1q8z00rlmf4b9` (unchanged, byte-identical).

## Activation notes

Until `sudo nixos-rebuild switch --flake .#pb-x1` is run, the running
system still identifies as `laptop` (`/etc/hostname`, `hostname`
command, shell prompt). After the switch:

- `/etc/hostname` becomes `pb-x1`.
- New shells will see the new hostname; existing shells continue to
  display the cached `laptop` until restarted.
- `/etc/machine-id` is unchanged (so systemd journal continuity is
  preserved across the rename).
- Old `laptop`-named generations remain in the bootloader for
  rollback. To clean them up later: `sudo nix-collect-garbage -d` or
  `nh clean all`.
- Audio preset autoload continues to work — the `autoloadDevice`
  field in the bridge uses the PCI address of the audio sink, not
  the hostname.

## Unrelated change in working tree (not staged)

`flake-modules/login-ly.nix` had a manual edit (`bigclock = false` →
`true`) that I left unstaged. Not part of this rename commit; commit
it separately when ready.

## Open follow-ups

None for this rename. Future work flagged previously is unaffected:

- New hosts go in `flake-modules/hosts/<name>.nix` modeled on
  `pb-x1.nix` (full desktop) or `wsl.nix` (headless / multi-config).
- If a "headless server baseline" subset emerges across multiple
  servers, extract a shared `flake-modules/profiles/server.nix` then.
