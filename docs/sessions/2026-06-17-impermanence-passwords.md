# 2026-06-17 — impermanence passwords: native `passwd` via /etc copy-sync

**Final approach:** keep `mutableUsers = true`; persist the user/group
database across the root wipe by **copying** it to `/persist` (restore
before activation's `users` snippet, save on change + at shutdown).
Never bind-mount those files.

This file records both the dead end we hit and the design we landed on,
because the failure is the whole reason for the final shape.

## Why this session

`sudo nixos-rebuild switch` on pb-x1 started failing in activation. The
trail ran through three error shapes, each exposing the next layer of
the same root mistake: **`/etc/{passwd,shadow,group,gshadow,subuid,
subgid}` had been added to the impermanence persistence list, and
bind-mounting those files is incompatible with how NixOS rewrites
them.**

### Error 1 — "A file already exists at /etc/passwd!"

impermanence's `persist-files` snippet refuses to bind a `/persist`
source over a non-empty real file, and `/persist/etc/passwd` was never
seeded. Activation order is the cause:

```
#### snippet users          (update-users-groups.pl writes /etc/passwd …)
#### snippet createPersistentStorageDirs   deps = [ "users" "groups" ]
#### snippet persist-files                 deps = [ "createPersistentStorageDirs" ]
```

`users` always runs before `persist-files`, so `/etc/passwd` is a real
file before impermanence ever looks at it.

### Error 2 — "rename: Device or resource busy" in `users`

Once the binds were actually established, the next switch failed
earlier:

```
write_file '/etc/.tempXXXX' - rename: Device or resource busy
  at update-users-groups.pl line 23
Activation script snippet 'users' failed (16)
```

`update-users-groups.pl` writes these files with
`write_file($path, { atomic => 1, ... })` — a temp file + `rename()` —
and calls it **unconditionally on every activation** (lines 197/285/
317/385/386, for group/passwd/shadow/subuid/subgid). You cannot
`rename()` over a bind **mountpoint** → `EBUSY`. So once any of these is
bind-mounted, *every* `nixos-rebuild switch` fails the `users` snippet,
and a normal boot's `persist-files` unit re-establishes the bind so the
next switch breaks again. **Bind-mounting the user/group DB is simply
not viable.**

## The pivot: A → B

We first shipped option **A** — `mutableUsers = false` + a per-user
`hashedPasswordFile` under `/persist`, plus a `set-password.sh` helper
and install.sh prompting. It works and is the cleanest *declarative*
answer. But it disables `passwd`: it re-implements half of `passwd` as a
sudo-only admin tool. When the operator asked "can users change their
own passwords like `passwd`, are we being roundabout?", the honest
answer was yes-ish — so we switched to **B**.

## Decision — B: native `passwd`, persisted by copy-sync

`mutableUsers` stays at its default (`true`), so `passwd`, `chsh`,
`gpasswd`, `usermod`, … all work natively. The user/group DB is
persisted by **copying** to `/persist` — never bind-mounting (that's the
`EBUSY` trap above).

- **Restore** — an activation snippet `restorePersistedAuth`, ordered
  *before* the `users` snippet (`system.activationScripts.users.deps`
  gains it; it itself `deps = [ "specialfs" ]`). On a freshly-wiped boot
  `/etc/shadow` is missing, so it seeds the files from `/persist`;
  `update-users-groups` (mutableUsers = true) then *preserves* those
  passwords. The guard is `[ ! -s /etc/$f ] && [ -f /persist/etc/$f ]`:
  on a running-system `switch` the files are already populated, so we
  **skip** — never clobber live state with a staler `/persist` copy.
- **Save** — a `.path` unit watches all six files and runs
  `persist-auth-save.service` (a `cp -a --remove-destination` of each
  `/etc/<f>` → `/persist/etc/<f>`) on any change, so a `passwd` change
  persists promptly. `persist-auth-shutdown.service` runs the same copy
  at `ExecStop` to capture the very last change at poweroff.

Verified on the built system: snippet order is `specialfs →
restorePersistedAuth → users`; `mutableUsers = true`; the path unit
watches passwd/shadow/group/gshadow/subuid/subgid; the save script
carries a valid Nix-store shebang.

### Trade accepted

A password changed in the seconds before an *unclean* poweroff (kernel
panic / yanked power, where `ExecStop` never runs) could be lost if the
`.path`-triggered save also didn't land. In practice the path save fires
on the `passwd` write itself, so the window is tiny. This was the known
cost of B vs A, and the operator chose it for native `passwd`.

### Why this is preferable to bind-mount or to A

- vs **bind-mount**: copy avoids the atomic-rename `EBUSY` entirely.
- vs **A (mutableUsers=false + hashedPasswordFile)**: native `passwd`
  for every user, no custom hashing tool, no install-time prompting —
  the whole `set-password.sh` + `--extra-files` apparatus is gone.

## Changes

- `flake-modules/impermanence.nix`
  - `/etc/{passwd,shadow,group,gshadow,subuid,subgid}` stay OUT of the
    bind-mount persistence list (NOTE rewritten to explain copy-sync).
  - Added `restorePersistedAuth` activation snippet + the
    `system.activationScripts.users.deps` ordering.
  - Added `persist-auth-save.{service,path}` and
    `persist-auth-shutdown.service`, plus the shared `saveAuthScript`
    (`pkgs.writeShellScript`).
  - `mutableUsers` left at default `true` (the Option-A
    `mutableUsers = false` line is gone).
- `flake-modules/hosts/{pb-x1,m-pc,pb-t480}.nix` — back to
  `initialPassword = "changeme"` for every account. `ah-1`/`wsl` don't
  import impermanence and are untouched.
- Reverted the Option-A tooling: `scripts/set-password.sh` deleted,
  `scripts/install.sh` and `README.md` restored (no password prompting).

All three impermanence hosts build (pb-x1 real; placeholders with
`NIXOS_ALLOW_PLACEHOLDER=1 … --impure`).

## Apply / migration

- **Fresh install**: account starts at `initialPassword = "changeme"`;
  log in, run `passwd`, done — it persists from then on.
- **pb-x1 (A → B migration)**: just `sudo nixos-rebuild switch`. On the
  switch, `restorePersistedAuth` skips (live `/etc/shadow` is
  non-empty), `update-users-groups` preserves the current password, and
  the path/shutdown save writes it to `/persist/etc/shadow`. The
  Option-A leftovers `/persist/passwords/*` are now unused and can be
  removed: `sudo rm -rf /persist/passwords`.

## Memory

Down-voted the prior memory recommending bind-mount persistence of the
`/etc` auth files; the EBUSY incompatibility and the copy-sync remedy
are the durable lesson.
