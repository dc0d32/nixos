# 2026-05-16 — SL3 install-safety guardrails

Pre-flight hardening pass before the first non-`pb-x1` egghead
install (Surface Laptop 3, Intel). Two guardrails, neither user-
facing in normal happy-path flow.

## Why

Real risk during a bring-up:

1. **Wrong-disk wipe.** The live installer ISO usually appears as
   `/dev/sda` or `/dev/sdb`; the laptop's NVMe is `/dev/nvme0n1`.
   Get the `--disk` argument wrong and the wizard cheerfully wipes
   the USB stick mid-install, leaving you with no installer and
   no install. The previous "type YES (uppercase) to proceed"
   prompt didn't help — it confirmed *intent*, not *identity*.

2. **Bricked first boot.** SL3 graphics could fall over, `sddm`
   could refuse to start, X could segfault on an unsupported
   touchpad, etc. Without a known-good recovery path, the only
   option is "boot the installer again and start over". Burning
   a 4 GiB ISO + spinning the installer for 30 minutes to reach
   a TTY is a bad debugging loop.

## What ships

### Guardrail #4 — `host-setup.sh` disk-safety checks

New `guard_disk_safety()` runs after `show_disk` in `do_install`
and refuses the install unless ALL of these pass:

- **Live-ISO-source check.** Walks `/`, `/nix`, `/nix/store`,
  `/nix/.ro-store`, `/iso`, `/run/iso`, `/run/initramfs/live`,
  `/run/installer`; for each, takes the underlying device via
  `findmnt -n -o SOURCE --target`, then `lsblk -no PKNAME` to the
  parent block device. If the target `--disk` equals any of those
  parents, refuse — that disk is hosting the installer right now.

- **Min size.** `lsblk -bndo SIZE` on the target; refuse anything
  smaller than 16 GiB. Eliminates "I pointed it at `/dev/sr0` /
  `/dev/loop1`" mistakes.

- **No mounted partitions.** `lsblk -nrpo NAME,MOUNTPOINT $disk`
  with `awk '$2 != ""'`. Anything currently mounted (even at
  `/mnt`) means disko can't wipe the partition table cleanly.
  Operator must `sudo $0 --unmount` first.

- **Typed-back model + size confirmation.** Replaces the blunt
  "type YES" gate. Shows the disk's MODEL + SIZE via `lsblk
  -ndo`, normalizes both sides (lowercase, strip whitespace),
  and requires the operator to retype them. Far harder to muscle-
  memory past than `YES<enter>`.

All four are gated by `--force-disk` (env: `FORCE_DISK=1`). When
set, each failed check prints a `warning:` line instead of
aborting, and the typed-back prompt is skipped entirely. ONLY for
automated tests — every safeguard is off.

### Guardrail #5 — recovery root account in generated bridge

Two new wizard prompts in `egghead.sh`:

- `EGGHEAD_ROOT_PASSWORD` (default `recovery`, empty to skip)
  — plain text. Emitted as
  `users.users.root.initialPassword = "...";` in the bridge.

When `ROOT_PASSWORD` is non-empty, the bridge also gets:

```nix
services.openssh.settings = {
  PasswordAuthentication = true;
  PermitRootLogin = "yes";
};
```

so `ssh root@host` from the LAN works on first boot, even before
the display manager / HM activation runs. Operator can tighten
this post-install in the host bridge.

SSH-key recovery was considered (fetch `https://github.com/<u>
.keys` at install time, inline into the bridge). Dropped for
v1 — adds a network dependency to a step that should never
fail, and the user (`dc0d32`) didn't have a key uploaded for the
default URL anyway. Root password is plain enough.

## What didn't change

- `flake-modules/openssh.nix` — still just `enable = true;` with
  defaults. The recovery posture is per-host (only emitted by the
  wizard, only into wizard-generated bridges), not a global flip.
- Existing hosts (`pb-x1`, `ah-1`, `m-pc`) — no SSH-recovery
  block, no root password. They've been booting fine; no need to
  retrofit.
- `host-setup.sh` flow ordering — guard runs in the same place
  the old "type YES" prompt sat (step 4.5 in `do_install`), so
  the abort/rollback paths (`abort_revert`) still work
  identically. Removed the now-redundant final "type YES" block.

## TUI mirror

`packages/egghead/src/steps.tsx` gained one new step:
`ROOT_PASSWORD` (text, default `"recovery"`). The TUI is still
a pure input collector — it just forwards
`EGGHEAD_ROOT_PASSWORD=...` to the bash engine.

## Retire when

- A first-boot recovery-shell story shipped by upstream NixOS
  (the installer ISO grows a TUI; nixos-anywhere becomes the
  canonical bring-up) makes the bash wizard obsolete. Then both
  guardrails go with the wizard.
- `host-setup.sh --install` gets replaced by `nixos-anywhere`,
  whose --disk handling is conceptually similar but lives
  upstream.

## Bonus: bare-metal SL3 polish

While we were here:

- **`flake-modules/surface.nix`** — wraps nixos-hardware's
  `microsoft-surface-pro-intel` bundle (which itself imports
  `microsoft-surface-common`: linux-surface patched 6.18-LTS kernel,
  iptsd, surface-control, thermald config). The Pro-Intel module is
  explicitly documented to work on other Intel-based Surface devices
  including SL3. Operator opts in by appending `surface` to the
  features list at wizard time.
- **`boot.kernelPackages` is now `lib.mkDefault`** in egghead-
  generated bridges, so hardware modules that ship their own kernel
  (the surface module, future ThinkPad-only kernels, etc.) can
  override without an `mkForce` arms race.
- **Post-`nixos-install` summary echoes the recovery info.** New
  block in `host-setup.sh` `do_install_post` greps the generated
  bridge for `users.users.root.initialPassword` and prints it back
  to the operator as a "write this down before reboot" hint, along
  with the `ssh root@<host-ip>` recipe. When no root password is
  configured the block warns explicitly that recovery requires
  re-booting the installer.
- **README + AGENTS.md** got a real "first install on bare metal"
  walkthrough: secure-boot-off requirement, networking up before
  `nix run`, the `--extra-experimental-features` flake one-liner,
  the Surface opt-in note, and a pointer to the recovery posture
  for first-boot debugging.
