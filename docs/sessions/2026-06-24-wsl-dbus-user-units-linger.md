# 2026-06-24 — fix WSL `nixos-rebuild` dbus user-unit reload (enable linger)

## Symptom

Every `nixos-rebuild switch` inside the WSL NixOS distro ended with:

```
reloading user units for p...
Error: Failed to open dbus connection

Caused by:
    Unable to autolaunch a dbus-daemon without a $DISPLAY for X11
warning: user activation for p failed
...
returned non-zero exit status 4.
```

`wsl --shutdown` did not help — the complaint came back on the next
boot of the WSL VM. The switch otherwise "worked" (home-manager
activation continued), but it always exited non-zero, which is noisy
and breaks any automation that checks the exit code.

## Root cause

The error is **not** cosmetic and **not** about a missing X server. It
is the modern Rust `switch-to-configuration-ng` failing to reach user
`p`'s **session** D-Bus during its final "reload user units" phase.

Mechanism, traced through the actual `switch-to-configuration-ng`
source (`.../switch-to-configuration-ng/src/main.rs`):

1. The system-scope parent lists logind users (`logind.list_users()`)
   and, for each, re-execs **itself** as that uid/gid to do the
   per-user unit reload (`main.rs:2243-2289`).
2. The re-exec uses `.env_clear()` and sets **only** `XDG_RUNTIME_DIR`
   (`main.rs:2273-2274`). So the child does **not** inherit
   `DBUS_SESSION_BUS_ADDRESS`.
3. The user-scope child immediately calls
   `LocalConnection::new_session()` (`main.rs:1299`). With no
   `DBUS_SESSION_BUS_ADDRESS`, libdbus relies on its implicit default:
   if `$XDG_RUNTIME_DIR/bus` exists it uses that; otherwise it falls
   back to **`autolaunch:`**, which needs an X11 `$DISPLAY`. Hence the
   exact wording "Unable to autolaunch a dbus-daemon without a
   `$DISPLAY` for X11".

So the whole thing hinges on whether `/run/user/<uid>/bus` exists at
switch time. That socket is created by `dbus.socket` inside the user's
`user@<uid>.service` systemd instance.

- On a **desktop**, the graphical/login session keeps
  `user@<uid>.service` running, so the socket is always there and the
  reload connects fine — which is why this was never seen on bare
  metal.
- On **WSL** there is no such session. logind still *lists* `p` (you
  are "logged in" to the distro shell), so STC-ng tries the reload, but
  the user manager / `dbus.socket` isn't up → no
  `/run/user/<uid>/bus` → autolaunch fallback → failure → `exit 4`.

`wsl --shutdown` couldn't fix it because nothing brought the user
manager up at boot.

## Fix

Enable **lingering** for the WSL login user in
`flake-modules/wsl.nix`:

```nix
users.users.${config.wsl.defaultUser} = {
  shell = lib.mkForce pkgs.zsh;
  linger = true;
};
```

`linger = true` makes logind start `user@<uid>.service` at boot,
independent of any interactive session. That instance starts
`dbus.socket`, so `/run/user/<uid>/bus` exists by the time STC-ng
re-execs as `p`, and the reload connects via the implicit
`$XDG_RUNTIME_DIR/bus` path. As a bonus, systemd **user** timers
(e.g. the two-stage nix-gc in `nix-settings-hm.nix`) now fire without
needing an active login session — previously they'd only run when
someone happened to be logged in.

Implementation note: `shell` and `linger` had to be merged into one
`users.users.${config.wsl.defaultUser} = { ... }` block. Two separate
statements with the same **dynamic** attribute key
(`users.users.${config.wsl.defaultUser}.shell` and
`....linger`) are a Nix "dynamic attribute already defined" error.

## Verification

- `nix eval .#nixosConfigurations.{wsl,wsl-arm}.config.users.users.p.linger`
  → `true` for both arches.
- Shell unchanged: `...users.p.shell.name` → `zsh-5.9`.
- Full smoke build: `nix build
  .#nixosConfigurations.wsl-arm.config.system.build.toplevel` (aarch64,
  builds natively on the dev box) succeeds.

## Applying it / caveat

```sh
cd ~/nixos && git pull
sudo nixos-rebuild switch --flake .#wsl     # or .#wsl-arm
wsl --shutdown                              # from Windows, then reopen
```

The **first** switch that applies this may still print the warning
once: the linger marker is written during the same activation that
runs the user-unit reload, so there's a race where the bus socket
isn't up yet for that run. After the `wsl --shutdown` + reboot,
`user@<uid>.service` starts at boot and every subsequent switch is
clean. Confirm with:

```sh
loginctl show-user p -p Linger   # Linger=yes
ls /run/user/1000/bus            # exists
```

## Retirement condition

Drop this `linger = true` if either: switch-to-configuration-ng stops
re-exec'ing into a per-user dbus session for unit reloads (e.g. it
learns to set `DBUS_SESSION_BUS_ADDRESS` explicitly or to skip users
with no running manager), or WSL is no longer a NixOS host in this
repo.
