# 2026-04-30 — Wire timekpr-nExT into family-laptop

Follow-up to `2026-04-30-family-laptop-host.md`. Originally planned to
package timekpr-next from upstream; mid-session I (the agent) realized
nixpkgs already ships it as `pkgs.timekpr` (same Launchpad project,
different attribute name). Discarded the in-progress packaging work
and wired the existing nixpkgs derivation instead.

## Lesson

Before writing a custom derivation, check nixpkgs by both upstream
project name AND any common aliases / `Provides:` lines from Debian
packaging. `timekpr-next` is the upstream project; nixpkgs exposes it
as `pkgs.timekpr` (the older `timekpr` is long retired and never
shipped on nixpkgs unstable). I missed this and started writing
`packages/timekpr-next/default.nix` from scratch, including pulling
the upstream tarball, manually wrapping the GTK/Cairo/D-Bus bindings,
and patching the systemd unit. The user caught it with "isn't it
already in nixpkgs?". Verified, discarded, started over with the
existing package. ~30 minutes lost. Cost would have been higher if
I'd actually committed the packaging.

Generalized check: when adding ANY new package to this flake, before
writing a derivation, run

  nix search nixpkgs <upstream-name>
  nix search nixpkgs <project-shortname>
  nix-locate <one-of-the-binaries-the-package-installs>

at minimum. Bonus: grep the nixpkgs `pkgs/by-name/` tree for the
upstream maintainer's GitHub handle.

## What was added

**`flake-modules/timekpr.nix`** — new NixOS cross-class module
implementing the dendritic Pattern A wrapper around `pkgs.timekpr`
(timekpr-nExT 0.5.8 in current nixpkgs HEAD). Importing IS enabling.

Top-level options:

```nix
options.timekpr.users = attrsOf (submodule {
  options = {
    allowedHours = "HH:MM-HH:MM";        # uniform across weekdays
    dailyBudgetMinutes = positive int;
    lockoutType = enum [ "lock" "suspend" "suspendwake"
                         "terminate" "kill" "shutdown" ];  # default "terminate"
    trackInactive = bool;                                  # default false
  };
});
```

The module:

1. Adds `pkgs.timekpr` to `environment.systemPackages` (puts
   `timekpra`, `timekprc`, `timekprd` on PATH).
2. Registers `pkgs.timekpr` with `services.dbus.packages` so
   the upstream-shipped policy at
   `${pkgs.timekpr}/etc/dbus-1/system.d/timekpr.conf` is loaded by the
   dbus-aggregation drv. Verified: the resulting
   `/etc/dbus-1/system.conf` includes
   `<includedir>${pkgs.timekpr}/etc/dbus-1/system.d</includedir>` as
   the very first include, so dbus picks up the policy at runtime
   even though no symlink ends up at
   `/etc/dbus-1/system.d/timekpr.conf` directly. (D-Bus on NixOS
   doesn't aggregate via `/etc`; it aggregates via `<includedir>`
   directives in `system.conf`.)
3. Creates the `timekpr` group with GID 2000, matching the
   Debian/Ubuntu postinst convention so the same group survives a
   data migration to/from a non-NixOS host. The D-Bus policy grants
   admin-interface access to this group.
4. Symlinks the package's pre-realized main config into
   `/etc/timekpr/timekpr.conf`. The shipped file already has
   `TIMEKPR_SHARED_DIR` patched to the nix store path, so we don't
   have to template it.
5. Adopts the upstream systemd unit
   `${pkgs.timekpr}/lib/systemd/system/timekpr.service` wholesale via
   `systemd.packages = [ pkgs.timekpr ]` plus an explicit
   `wantedBy = [ "multi-user.target" ]` to enable it.
6. Renders per-user policy files into the nix store via
   `pkgs.writeText` and seeds them at
   `/var/lib/timekpr/config/timekpr.<user>.conf` with
   `systemd.tmpfiles.rules` using the `C` (copy-if-missing) verb.

## Why `C` (copy-if-missing) and not `L` (symlink) for per-user files

The timekpr daemon REWRITES `timekpr.<user>.conf` whenever the admin
adjusts a limit through `timekpra` (GUI) or `timekprc` (CLI). If we
symlinked into `/nix/store`, the rewrite would either fail (read-only
store) or — worse — break the symlink and end up with a divergent
copy that no longer mirrors the declared defaults. Tmpfiles `C`
seeds the file once, then leaves it alone. To force a re-seed:

```sh
sudo rm /var/lib/timekpr/config/timekpr.<user>.conf
sudo systemctl restart systemd-tmpfiles-resetup
```

(Or just rebuild + reboot.)

This is a deliberate trade-off between "fully declarative" and
"runtime mutability". Parental controls have to be tweakable in the
moment ("ok, 30 more minutes for homework") so runtime mutation wins.
The declared defaults are the floor / reset point.

## Per-kid policies on family-laptop

Set in `flake-modules/hosts/family-laptop.nix`:

```nix
timekpr.users = {
  m = { allowedHours = "06:00-21:00"; dailyBudgetMinutes = 240; };
  s = { allowedHours = "07:00-22:00"; dailyBudgetMinutes = 360; };
};
```

`p` is unrestricted (not listed) but is added to the `timekpr` group
via `extraGroups = [ ... "timekpr" ]` so they can drive `timekpra`
to grant ad-hoc time or change the policy at runtime.

`lockoutType` defaults to `terminate` for both kids (matches Windows
Family Safety's hard cutoff). If we want a softer "lock and they can
unlock with a parent password" experience later, change to `lock`.

## "HH:MM" parsing pitfall

`lib.toInt "06"` throws "Ambiguity in interpretation between octal
and zero padded integer". Worked around with a small `stripZeros`
recursive function. Could also have used `lib.fromJSON` but
`stripZeros` is cheaper and explicit.

## Closure regression check

Baselines captured before changes and verified afterward:

| host | baseline closure | post-change | identical? |
|---|---|---|---|
| pb-x1 | `cbxci9lv0kg7xgkk2pvl1xqyplzn3r8w` | same | yes |
| wsl | `f8pc9csn7cp1qzcx753cp80ny7wjb141` | same | yes |
| family-laptop | `bj7dw8rsm7ks953gdlnyhgvqwhzc3ggm` | `i7jqgf2ci3k704qxg9b8nlmnlc8gzr47` | NO (expected — that's the whole point) |

Home-manager configs:

| config | baseline | post-change | identical? |
|---|---|---|---|
| `p@pb-x1` | `ds56glplhvl53m19jwfzymairxyg1780` | same | yes |
| `p@family-laptop` | n/a | `isrna8pgc6gp0pv1k4mvgwvxvkgzn98c` | n/a |
| `m@family-laptop` | n/a | `8ryzls2vvafs4hsmffnig1bqlf33igxn` | n/a |
| `s@family-laptop` | n/a | `09x8qqp3il658gx2zy044w86x15y7g0y` | n/a |

`wsl-arm` doesn't build on x86_64 without binfmt/cross setup; this
is a pre-existing limitation of the dev box, NOT a regression caused
by these changes (verified by reproducing the failure on a clean
working tree before any edits).

## What's NOT in this commit

- No `family-activity` change. The wrapper was already added in
  commit `b6e5225` (the family-laptop scaffold) — it shells out to
  `journalctl --grep "session (opened|closed) for user (m|s)"`. The
  prior session note's TODO item to "add family-activity" was
  out-of-date.
- No web filtering, no DNS resolver/logging — both deferred per the
  scoping decisions captured in `2026-04-30-family-laptop-host.md`.
- No host-bridge changes for pb-x1 / wsl / wsl-arm.

## Verifying on the actual hardware (post-deploy)

Once the family-laptop is built out (real hwconfig in
`hosts/family-laptop/hardware-configuration.nix`) and switched to:

```sh
# Daemon should be active.
systemctl status timekpr
# p should be in the timekpr group.
groups p | tr ' ' '\n' | grep timekpr
# Per-user files should be present and match the declared limits.
sudo cat /var/lib/timekpr/config/timekpr.m.conf
sudo cat /var/lib/timekpr/config/timekpr.s.conf
# Admin GUI should launch for p.
sudo -u p timekpra
# CLI status check.
sudo timekprc --userinfo m
sudo timekprc --userinfo s
```

## Files touched

- `flake-modules/timekpr.nix` — new (224 lines)
- `flake-modules/hosts/family-laptop.nix` — wire it in:
  - imports `config.flake.modules.nixos.timekpr`
  - sets `timekpr.users.{m,s}`
  - adds `"timekpr"` to `users.users.p.extraGroups`
  - rewrites the "screen-time TODO" header comment
