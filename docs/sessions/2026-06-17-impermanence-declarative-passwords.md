# 2026-06-17 — impermanence passwords: stop bind-mounting /etc, go declarative

**Commit:** `4c98170` (on top of `5a367fb` lockscreen fix; replaces an
earlier bad commit `8915428` that was soft-reset away before push).
Not pushed.

## Why this session

`sudo nixos-rebuild switch` (`nr`) on pb-x1 started failing in the
activation phase. The trail ran through three distinct error shapes,
each one exposing the next layer of the same underlying mistake:
**`/etc/{passwd,shadow,group,gshadow,subuid,subgid}` had been added to
the impermanence persistence list, and bind-mounting those files is
fundamentally incompatible with how NixOS rewrites them.**

### Error 1 — "A file already exists at /etc/passwd!"

The first `nr` aborted in impermanence's `persist-files` activation
snippet:

```
A file already exists at /etc/passwd!
...
Activation script snippet 'persist-files' failed (1)
```

Upstream impermanence's `mount-file` helper refuses to bind a
`/persist` source over a target that is already a **non-empty real
file**, and `/persist/etc/passwd` had never been seeded. So nothing
was persisted and activation failed.

Diagnosis of the activation order (from the built `activate` script):

```
#### snippet users          (update-users-groups.pl writes /etc/passwd …)
#### snippet createPersistentStorageDirs   deps = [ "users" "groups" ]
#### snippet persist-files                 deps = [ "createPersistentStorageDirs" ]
```

`users` **always** runs before `persist-files`, so by the time
impermanence tries to bind `/etc/passwd`, NixOS has already written it
as a real file. The first (wrong) fix added a `seedPersistAuthFiles`
activation snippet ordered *after* `users` and *before* `persist-files`
that seeded `/persist/etc/<f>` from the freshly written `/etc/<f>` and
bind-mounted it. It built, ordered correctly, and was committed as
`8915428`.

### Error 2 — "rename: Device or resource busy" in `users`

With the binds now actually established (via a one-time recovery script
on the live host), the next `nr` failed earlier, in the `users` snippet
itself:

```
write_file '/etc/.tempXXXX' - rename: Device or resource busy
  at update-users-groups.pl line 23
Activation script snippet 'users' failed (16)
```

Reading `update-users-groups.pl` settled it:

```perl
sub updateFile {            # line ~20
    write_file($path, { atomic => 1, ... }, $contents) or die;
}
...
updateFile("/etc/group",  \@lines);   # line 197  — unconditional
updateFile("/etc/passwd", \@lines);   # line 285  — unconditional
updateFile("/etc/shadow", \@shadowNew, 0640);  # line 317
updateFile("/etc/subuid", ...);       # line 385
updateFile("/etc/subgid", ...);       # line 386
```

`File::Slurp`'s `{ atomic => 1 }` writes a temp file in `/etc` and
**`rename()`s it over the target**. You cannot `rename()` over a bind
**mountpoint** — the kernel returns `EBUSY`. And `updateFile` is called
**unconditionally on every activation** (no content-change guard). So:

> Once `/etc/passwd` (or any of these) is a bind mount, **every**
> `nixos-rebuild switch` fails the `users` snippet with `EBUSY` — and
> on a normal boot the persist-files unit re-establishes the bind, so
> the next switch breaks again.

The bind-mount approach (and therefore both `8915428` **and** the
original premise that added these files to the list) was never viable.
It simply hadn't been exercised, because on this host the binds had
never successfully been established until we forced them.

## Decision — declarative users, password via `hashedPasswordFile`

Chosen posture (operator picked the strictest of three options):
**`users.mutableUsers = false` + a per-user `hashedPasswordFile` under
`/persist`.** Rationale:

- `update-users-groups.pl` regenerates `/etc/{passwd,group,shadow,
  subuid,subgid}` deterministically every boot from declarative config
  plus the **already-persisted** `/var/lib/nixos` uid/gid maps. There is
  nothing mutable in them worth persisting — so they come off the list
  entirely.
- The only thing that genuinely needs to survive the root wipe is the
  **password hash**. `hashedPasswordFile` points at a file under
  `/persist` (read directly by its absolute path — no bind mount). On
  every activation `update-users-groups` reads it and writes
  `/etc/shadow` via its normal atomic rename onto the **real** (root
  subvol) file. No mountpoint, no `EBUSY`. The hash survives because it
  lives in `/persist`.
- Under impermanence `/etc/shadow` is wiped every boot anyway, so a
  runtime `passwd` change could never have survived. `mutableUsers =
  false` makes that explicit rather than a silent foot-gun, and matches
  the "rebuildable from declared state alone" goal of the whole
  impermanence effort.

### Why `mutableUsers = false` lives in the impermanence module

Set as `users.mutableUsers = lib.mkDefault false;` inside
`flake.modules.nixos.impermanence`. Importing impermanence now *implies*
declarative users — the wipe is what makes mutable users meaningless, so
the coupling is honest. `mkDefault` lets a host opt back in if it ever
ships its own `/etc/shadow`-survives-the-wipe mechanism (e.g. a
boot/shutdown copy service — the third option we did **not** take).

### Why not the other two options

- **`hashedPasswordFile` + keep `mutableUsers = true`** — works, but
  leaves a misleading affordance: `passwd` succeeds yet silently
  evaporates on reboot.
- **Boot/shutdown sync of `/etc/shadow`** — the only way to keep *true*
  runtime-mutable passwords across the wipe without bind-mounting, but
  more moving parts and a crash-window where the last change is lost.
  Not worth it for a single-operator laptop with a declarative ethos.

## Changes

- `flake-modules/impermanence.nix`
  - Removed `/etc/{passwd,shadow,group,gshadow,subuid,subgid}` from the
    persistence `files` list (with a NOTE explaining the `EBUSY`
    incompatibility so nobody re-adds them).
  - Removed the `seedPersistAuthFiles` activation snippet and the
    `persist-files.deps` override (the reverted `8915428` approach).
  - Added `users.mutableUsers = lib.mkDefault false;`.
- `flake-modules/hosts/{pb-x1,m-pc,pb-t480}.nix` — replaced
  `initialPassword = "changeme"` with
  `hashedPasswordFile = "/persist/passwords/<login>"` for every account
  (primary + kid users). `ah-1` and `wsl` don't import impermanence and
  are untouched.

All three impermanence hosts build (`pb-x1` real;
`NIXOS_ALLOW_PLACEHOLDER=1 … --impure` for `m-pc` / `pb-t480`).

## Apply runbook (per host) — ORDER MATTERS

With `mutableUsers = false` a missing `hashedPasswordFile` means a
**locked account**. Create the hash *before* switching:

```sh
# 1. Create the password hash FIRST (else you lock yourself out)
sudo install -d -m 700 /persist/passwords
mkpasswd -m sha-512 | sudo tee /persist/passwords/<login> > /dev/null
sudo chmod 600 /persist/passwords/<login>

# 2. On a host where the old binds are live, detach them so
#    update-users-groups can rename() again
sudo umount /etc/passwd /etc/shadow /etc/group /etc/subuid /etc/subgid

# 3. Switch
sudo nixos-rebuild switch --flake .#<host>

# 4. Verify BEFORE rebooting (while still logged in)
sudo -k && sudo -v

# 5. Optional: drop the stale files the recovery seed wrote
sudo rm -f /persist/etc/{passwd,shadow,group,subuid,subgid,gshadow}
```

`root` ends up locked (declarative, no password); `sudo` via `wheel`
still works. Add a `users.users.root.hashedPasswordFile` if rescue-shell
access is wanted.

## Fresh-install implication

A fresh `nixos-anywhere` install of an impermanence host now needs
`/persist/passwords/<login>` to exist at first boot, or the account is
locked. Bootstrap options for next time: seed it via
`nixos-anywhere --extra-files`, or boot once, create the hash from the
installer/root shell, reboot. (Not wired into `scripts/install.sh` yet —
flagged here so it isn't a surprise.)

## Aside — `.zsh_history` on the surviving `/home` subvol

While untangling the above we also found `.zsh_history` (a
`userFiles` entry) failing the same "file already exists" check. Its
cause is different and benign: `/home` is a **separate surviving
subvol**, so a pre-existing real file there shadows the bind. Unlike the
`/etc` files it does **not** use atomic rename (zsh appends), so the
bind itself is fine once established — the fix was a one-time
operational cleanup (empty the stale underlying file so the boot-time
bind finds an empty/absent target). No config change; left as a manual
step. Fresh installs never hit it (empty `/home` → upstream's symlink
branch self-heals).

## Memory updated

Down-voted the prior repo memory that recommended persisting
`/etc/{passwd,shadow,…}` under impermanence; stored the correct rule:
*never bind-mount those files — use `mutableUsers = false` +
`hashedPasswordFile` under `/persist`.*
