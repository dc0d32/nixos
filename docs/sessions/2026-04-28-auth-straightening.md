# 2026-04-28 — Auth story straighten-out

## Goal

Fix three production bugs reported after deploying phase 4:

1. **ly login**: typing the password didn't proceed to login until the user
   *also* touched the fingerprint reader.
2. **Post-login key vault prompt**: a popup appeared after every login asking
   for the password again to unlock a "key vault" (gnome-keyring).
3. **Face unlock not working**: howdy was wired into PAM but didn't
   authenticate.

Adjacent: no polkit GUI agent was running, so any polkit-driven prompt
(e.g. Bitwarden biometric unlock per `biometrics.nix:63-69`) had nowhere to
render in the Wayland session.

## Context

Continues from the OSD-overlay fix (`fc054ad`). Phase 4's session log
already noted "follow-up: revisit auth ordering when biometrics are
exercised in real use" — this session does that.

The investigation revealed the resolved `/etc/pam.d/ly` auth stack was:

```
auth sufficient pam_howdy.so       # order 11390
auth sufficient pam_fprintd.so     # order 11400  ← blocks on sensor read
auth optional   pam_unix.so likeauth                      # 11700
auth optional   pam_gnome_keyring.so                      # 12200
auth sufficient pam_unix.so likeauth try_first_pass       # 12900  ← password actually checked
auth required   pam_deny.so                               # 13700
```

`pam_fprintd.so` is a synchronous device read: when ly hands the typed
password to PAM, fprintd blocks waiting for a finger swipe before PAM can
reach the `pam_unix.so` line that would verify the password. Touching the
reader satisfies fprintd and the rest of the stack runs. **This is the root
cause of bug 1.**

The same short-circuit explains bug 2: when login completes via biometrics
(or via password but PAM short-circuits early), `pam_unix-early` and
`pam_gnome_keyring` never run, so the keyring daemon starts with no master
password and prompts on first libsecret consumer (Chrome, Bitwarden, etc.).

For bug 3 the explorer initially suspected howdy wasn't auto-wired into
ly, but `nix eval .#…security.pam.services.ly.text` proved otherwise —
howdy is at order 11390 in the resolved stack. The failure is operational:
either device path drift (`/dev/video2` doesn't always point at the IR
camera after USB enumeration), missing enrollment, or IR emitter not
configured. We can't diagnose hardware from the flake; we can make the
device-path detection robust.

## Design decisions

The user picked, in order:

1. **PAM ordering**: closest practical analogue to "Windows Hello-style
   last-used-method-first" — since PAM is stateless and walks rules in fixed
   order, we approximate it by putting `pam_unix.so try_first_pass` first.
   If a password was typed, unix verifies and short-circuits the stack —
   biometrics are skipped, no waiting. If no password (or wrong password),
   PAM falls through to howdy then fprintd.
2. **Keyring**: solved as a free side effect of the reorder above —
   `pam_unix-early` (already at 11700) captures the password into
   `PAM_AUTHTOK`, and `pam_gnome_keyring` (at 12200) consumes it before
   the sufficient-unix at 12900 short-circuits.
3. **Face unlock**: auto-detect the IR camera device path at boot via a
   systemd one-shot, instead of hardcoding `/dev/video2`.
4. **polkit agent**: add `hyprpolkitagent` autostarted via niri's
   `spawn-at-startup` so polkit-driven prompts render correctly.

## Changes

### 1. `modules/nixos/biometrics.nix` — PAM reorder + IR autodetect

Replaced the previous howdy/fprintd `order = ... fprintd.order - 10` arithmetic
(which was broken — see "Bug in the bug fix" below) with explicit fixed
orders applied uniformly to `login`, `sudo`, `ly`, and `bitwarden` PAM
services:

```nix
howdy.order   = 12950;
fprintd.order = 13000;
deny.order    = 13100;   # forced last so we don't get stranded behind it
```

The `deny.order` override was necessary because the default deny order
varies per service: `login` and `ly` have it at `13700` (after our biometric
slots), but `sudo` and `bitwarden` default to `12500` — *before* our
biometrics. Without forcing deny later, biometric fallback was dead on
sudo/bitwarden. The fixed `13100` keeps deny last while not disturbing any
modules in the `11000–12950` range.

Resolved `ly` auth stack post-fix:
```
auth optional   pam_unix.so likeauth              # 11700  capture password
auth optional   pam_gnome_keyring.so              # 12200  unlock keyring with captured pw
auth sufficient pam_unix.so try_first_pass        # 12900  verify pw, short-circuit on success
auth sufficient pam_howdy.so                      # 12950  face fallback
auth sufficient pam_fprintd.so                    # 13000  finger fallback
auth required   pam_deny.so                       # 13100  forced last
```

Identical structure for `sudo` and `bitwarden` (without the gnome-keyring
chain since those services don't run it).

Also added a `cameraDevice` variables knob (default `/dev/video2`) used as
the initial config and as the fallback if autodetect finds nothing.

### 2. `modules/nixos/biometrics.nix` — howdy-camera-autodetect.service

New `systemd.services.howdy-camera-autodetect`:

- Type: `oneshot`, `RemainAfterExit = true`, runs after
  `systemd-udev-settle.service`.
- Walks `/dev/video*`, runs `v4l2-ctl --device <node> --info` on each, and
  picks the first node whose "Card type" contains `infrared`, `IR camera`,
  `IR cam`, or `HelloCam` (case-insensitive).
- Rewrites `/etc/howdy/config.ini`'s `device_path` line in-place. The file
  is normally a symlink into `/nix/store`; the script breaks the link
  atomically (mktemp + sed + rm + mv).
- If no IR-capable device is found, leaves the config untouched and exits 0.
- `pkgs.v4l-utils` added to `environment.systemPackages` so users can run
  `v4l2-ctl --list-devices` to debug.

This is gated on `enabled` (i.e. `variables.biometrics.enable`) so non-
biometric hosts don't get the unit.

### 3. `modules/home/desktop/polkit-agent.nix` — new module

New home-manager module installs `hyprpolkitagent` and adds it to niri's
`spawn-at-startup`. Despite the name, hyprpolkitagent works in any Wayland
compositor — it speaks the standard polkit Authentication Agent D-Bus
interface. Gated on `desktop.niri.enable`.

Added to `modules/home/default.nix:34` (between `niri.nix` and
`waybar.nix`).

### 4. Naming and ordering of the autodetect service

The systemd unit name is `howdy-camera-autodetect.service` rather than
`udev-howdy-camera.service` — it's a oneshot that runs once after udev
settles, not a udev rule itself. Documented in the module comment that this
should be retired when nixpkgs ships `services.howdy.device.autodetect` or
when stable `/dev/v4l/by-id/` symlinks for IR cameras become reliable.

## Bug in the bug fix (caught by `nix eval`)

First implementation hardcoded `howdy.order = 12950` and `fprintd.order = 13000`
without touching `deny.order`. The build succeeded but `nix eval .#…sudo.text`
showed the bug:

```
auth sufficient pam_unix.so try_first_pass     # 11700
auth required   pam_deny.so                    # 12500   ← STILL HERE
auth sufficient pam_howdy.so                   # 12950   ← UNREACHABLE
auth sufficient pam_fprintd.so                 # 13000   ← UNREACHABLE
```

`pam_deny` at order 12500 was BEFORE our biometric slots. Sudo still worked
on a correct password (unix at 11700 short-circuits), but biometric
fallback was dead — exactly the same class of bug as the original. Fixed
by also pushing `deny.order` to 13100 in the same `reorder` attrset.

The lesson: **always inspect `nix eval .#…security.pam.services.<svc>.text`
after touching PAM ordering**, not just `nix build`. The build doesn't
catch logically dead rules.

## Verification

```sh
git add modules/nixos/biometrics.nix \
        modules/home/desktop/polkit-agent.nix \
        modules/home/default.nix
nix fmt
nix flake check                                              # all checks passed
nix build .#nixosConfigurations.laptop.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.wsl.config.system.build.toplevel    --no-link
nix build '.#homeConfigurations."p@laptop".activationPackage'       --no-link
```

PAM stacks verified post-build:

```sh
for svc in login sudo ly bitwarden; do
  echo "=== $svc ==="
  nix eval --raw .#nixosConfigurations.laptop.config.security.pam.services.$svc.text \
    | grep '^auth'
done
```

All four services show the `unix(sufficient) → howdy → fprintd → deny`
ordering, with `unix-early` and `gnome_keyring` correctly sequenced ahead
of `unix(sufficient)` on `login` and `ly`.

`spawn-at-startup` post-fix includes hyprpolkitagent:

```sh
$ nix eval --json '.#homeConfigurations."p@laptop".config.programs.niri.settings.spawn-at-startup'
[
  {"command":[".../bitwarden","--silent"]},
  {"command":[".../libexec/hyprpolkitagent"]},
  {"command":["easyeffects","--gapplication-service"]},
  {"command":["quickshell"]},
  {"command":["stasis"]}
]
```

## Files

- New: `modules/home/desktop/polkit-agent.nix`
- Modified:
  - `modules/nixos/biometrics.nix` — PAM reorder + IR autodetect service
  - `modules/home/default.nix` — register polkit-agent module

## Follow-ups for the user (out of agent scope)

1. **Reboot or `sudo nixos-rebuild switch --flake .#laptop`** to apply PAM
   reorder + start `howdy-camera-autodetect.service`.
2. **`home-manager switch --flake .#"p@laptop"`** to start hyprpolkitagent
   on the next niri session start (or restart niri).
3. **Verify camera autodetect**: `systemctl status howdy-camera-autodetect`
   and `cat /etc/howdy/config.ini | grep device_path`. If it picked the
   wrong device, list available v4l devices with `v4l2-ctl --list-devices`
   and tell us the IR camera's "Card type" string so we can extend the
   match list.
4. **Re-enroll face** if the device path changed:
   `sudo howdy clear && sudo -E linux-enable-ir-emitter configure && sudo howdy add`.
5. **Test face unlock**: `sudo howdy test` (will show camera feed with face
   detection overlay) and `sudo -k && sudo echo ok` (should work without
   password if face is enrolled correctly).
6. **Test the keyring fix**: log out, log back in with the typed password;
   the "key vault" prompt should not appear. (If you log in with finger,
   the prompt WILL appear — that's by design; biometrics provide no
   password to unlock the keyring with.)
7. **Test polkit agent**: trigger a Bitwarden biometric unlock; the polkit
   prompt should now render in the Wayland session instead of silently
   failing.

## Follow-ups for next session

- The `face-doctor` script idea (declined this session in favor of
  autodetect) might still be useful as a `nix run .#face-doctor` debug
  command — surveys v4l devices, IR emitter, howdy enrollment, and runs a
  test capture. Defer until the autodetect approach is proven.
- `services.howdy.includedServices` (or the equivalent option in this
  nixpkgs revision) was not investigated; we relied on the `services.howdy`
  module auto-extending all standard PAM services. If face unlock works
  but feels selectively missing somewhere, this is the next thing to look at.
- The `enableGnomeKeyring` flag is currently inherited from somewhere in
  the desktop chain (`true` for both `login` and `ly`). Worth tracing where
  exactly so we can document the dependency in `biometrics.nix`.
