# 2026-05-17 — impermanence + restic backup to TrueNAS

## Why this session

Operator wanted to egghead-refresh every NixOS host in the fleet
(pb-x1, pb-t480, m-pc) to absorb recent disko / swap-partition
changes, but without losing the substantial pile of non-Nix-managed
state each host has accumulated since first install (browser
profiles, Bitwarden vault, FreeCAD prefs, KiCad libraries,
NetworkManager keyrings, ad-hoc dotfiles, the operator's working
trees under `~/nixos` / `~/src` / `~/Documents`, etc.).

Two coupled requirements:

1. Make the host fundamentally re-buildable from declared state
   alone — egghead-refresh shouldn't be a recurring "now spend a
   day re-customizing" event. Anything that isn't declared in the
   flake AND isn't on an explicit persistence list should be gone
   on every boot. That's **impermanence**.

2. Restore the per-user state after a refresh from an off-host
   backup. Local-only backups don't survive a hardware loss; we
   already have a TrueNAS on the LAN. That's **restic over SFTP**.

## Decisions

### Why restic, not btrbk / borgbackup / duplicati

* **btrbk / btrfs send-receive** needs btrfs on the destination.
  TrueNAS is ZFS at the pool level, so streamed btrfs blobs would
  be opaque to the NAS — no dedup, no incremental restore, no
  useful retention. Loses most of btrbk's value.
* **borgbackup over SSH** would also work but `borg serve` has to
  be installed on the destination. On TrueNAS that means a Custom
  App or plugin — more NAS-side setup than the operator wanted.
* **Duplicati** needs a long-running daemon on every backed-up host,
  stores credentials in its own SQLite DB (one more credential
  surface), and the historical reliability of its restore path has
  produced multiple user-side data-loss reports. Disqualifying for
  "must work on first restore after egghead-refresh".
* **restic over SFTP** needs only sshd + an unprivileged user on
  the NAS. Zero NAS-side install. Dedup + symmetric encryption +
  retention all client-side. nixpkgs already ships
  `services.restic.backups.<name>` (timer + service + network-online
  wait); we add a thin layer for the btrfs-snapshot consistency
  wrapper, the AC-power gate, and a restore / seeding wrapper.

### One repo per host, not per user

* restic dedup is repo-scoped — splitting per user repays storage
  for files two users share (caches, package downloads, etc.).
* Per-domain restore granularity is preserved via restic `--tag`
  + `--include` filters at restore time.
* Cross-host isolation is total: every host's repo is at a
  hostname-specific path under `<repoBasePath>/<hostname>` and is
  encrypted with its own password. The **shared** `restic-backup`
  SSH user on the NAS can READ every repo (which is what enables
  cross-host seeding), but only a host that knows the matching
  repo password can decrypt anything.

### Cross-host seeding is a first-class egghead step

* The whole point of impermanence + backup is to make refreshes
  cheap, and the highest-pain part of a refresh is "all my user
  state is gone, now I have to remember to restore it". So egghead
  walks every declared user (PRIMARY_USER + EXTRA_USERS) and asks:
  "Seed this user's persisted state from another host? Yes/no →
  paste source host name, source user login, source repo password".
* Seeded data is restored INTO `/persist/home/<this-login>/` so
  that on first boot, the NixOS impermanence module's bind mounts
  expose it at the right places under `/home/<this-login>/`.
* Seeding NEVER pulls `/persist` itself: machine-id, NetworkManager
  connections, SSH host keys, etc. are host-specific and would
  break the new host if copied across.
* User-rename is supported: pull `pb-x1`'s `p`-user state into a
  new host's `alice` user with `backup-restore --seed-from-user p
  --seed-to-user alice`.

### Why single NixOS module, not NixOS-side + HM-side impermanence

This was a mid-implementation pivot. Initial sketch had
`flake-modules/impermanence-hm.nix` (a homeManager-class module
contributing `home.persistence."${homeDirectory}/persist"`),
mirroring the upstream impermanence README's HM module example.

Smoke-build failed with "The option `home.persistence` does not
exist", and digging into the upstream flake revealed the
`homeManagerModules.impermanence` attr is now a **deprecated
shim** that emits an assertion: the HM module is supposed to be
auto-loaded by the NixOS module when home-manager is wired in as a
NixOS module.

We deliberately don't wire HM into NixOS (CLAUDE.md hard rule),
because HM stays standalone so the same user modules can apply on
macOS later. Options:

* **A:** Wire HM as a NixOS module. Violates the hard rule and
  introduces a coupling we'd have to unwind for a future
  nix-darwin port. Rejected.
* **B:** Implement bind-mounts manually in pure HM via systemd
  user units. Substantial work, and re-derives a feature upstream
  already provides. Rejected.
* **C:** Use the NixOS impermanence module's
  `environment.persistence."<path>".users.<login>` sub-attribute,
  which provides exactly the same per-user bind-mount machinery
  WITHOUT requiring the HM module. The persisted paths are
  prefixed with the user's home dir automatically, stored under
  `/persist/home/<login>/.<path>`. Identical user-facing behavior
  to the HM module; lives entirely on the NixOS side.

**Chose C.** Deleted `flake-modules/impermanence-hm.nix` and moved
the per-user default list into `options.impermanence.userDirectories`
+ `userFiles` (declared on the NixOS module). The defaults are
applied to every normal user via
`environment.persistence."/persist".users = lib.mapAttrs (...) normalUsers`.
Hosts can override per-user via plain
`environment.persistence."/persist".users.<login>.directories = [...]`
in the bridge.

Side effect: per-user state and system state now both live under
`/persist`, so the backup service only needs to snapshot `/persist`
(was `/persist` + `/home`). Simpler. The disko factory still creates
a separate `home` btrfs subvol — it's now strictly ephemeral
(bind-mount destinations), but keeping it as its own subvol lets
btrfs quota / future split decisions stay open.

### Smoke-build bugs caught (worth remembering)

* **Infinite recursion in `fileSystems`.** First version of
  impermanence.nix had `fileSystems = lib.mkIf (config.fileSystems ?
  ${cfg.persistRoot}) { … };` which is a self-reference: the block
  IS a definition of `config.fileSystems`. Fixed by unconditional
  `fileSystems.${cfg.persistRoot}.neededForBoot = lib.mkDefault
  true;`. If the host's disko doesn't actually create `/persist`,
  the explicit `assertions = [...]` block at the bottom of the
  module catches it (plus NixOS' own fileSystems validator will
  complain about a missing `device`).
* **`/home` needs `neededForBoot = true` too.** The impermanence
  assertion requires EVERY filesystem hosting a persistence target
  to be `neededForBoot`. Since `users.<login>` targets land under
  `/home/<login>/...`, the `/home` subvol now has to mount in
  initrd. Set `fileSystems."/home".neededForBoot = lib.mkDefault
  true;` alongside `/persist`.
* **`services.restic.backups.<name>.tags` doesn't exist.** Reached
  for the obvious-looking option name and it's not on the nixpkgs
  module. Pass `extraBackupArgs = [ "--tag" "auto" ]` instead.
* **`sftp.command` syntax for restic's `-o` flag.** Works as
  `extraOptions = [ "sftp.command=ssh -i ... -o ... %h" ]` (one
  entry per `-o` flag, the module concatMaps them onto restic's
  command line). The `%h` placeholder is restic's; it gets the
  hostname portion of the SFTP URL substituted at runtime.

### Endpoint-spoofing defense

`backup.knownHostsFile` (default `/persist/etc/ssh-restic/restic_known_hosts`)
pins the SFTP destination's SSH host key. The ssh command restic
invokes runs with `StrictHostKeyChecking=yes` + `BatchMode=yes`. So:

* Laptop on a hostile network where someone resolves `nas.lan` to
  an attacker → ssh refuses the handshake → no auth attempt, no
  data sent. The repo password is symmetric and never sent over
  wire anyway, so even if the attacker MITM'd the SSH layer (they
  can't, with `StrictHostKeyChecking=yes`) they'd see only
  ciphertext.
* The pinned host key is generated at install time by
  `ssh-keyscan` against the NAS, so the operator has to verify the
  NAS was actually reachable at install time. (Out-of-band
  fingerprint verification against the NAS's UI is recommended for
  the first install; subsequent installs are bootstrapped from
  the same NAS so the key is stable.)

### Wake-from-sleep handling

* Timer: `*-*-* 03:00:00` with `Persistent=true` and
  `RandomizedDelaySec=30m`. Persistent semantics catch missed runs
  on wake from S3 (laptop in a bag at 03:00).
* NOT `WakeSystem=true` — we deliberately don't yank a laptop out
  of S3 to back up. If it stays in a bag for a week, backup runs
  on the next wake.
* AC gate (`backup-wait-for-ac` writeShellApplication) polls
  `/sys/class/power_supply/{AC,ACAD,AC0,ADP1}/online` every 60s for
  up to 4h. No AC node found → assume desktop, proceed. AC present
  → proceed. After 4h with no AC → exit non-zero so the next timer
  fire retries.

### Re-install posture (operator pastes the old repo password)

Egghead's `IS_REINSTALL=yes` flow prompts for the existing repo
password (paste from password manager) and writes it verbatim to
`/persist/etc/restic/host.pass` instead of generating a fresh one.
The new install reuses the same repo URL (it's keyed on
`<hostname>`) and the same `restic-backup` SSH user. Only the
host's SSH private key is fresh — the operator pastes the new
pubkey into the NAS's authorized_keys (and removes the old one if
they want).

## Layout

```
flake-modules/
├── impermanence.nix    # NixOS module: rollback initrd unit, /persist
│                       # defaults, per-user environment.persistence
│                       # via users.<login>, cross-module signal
├── backup.nix          # NixOS module: restic-over-SFTP service,
│                       # AC-gate, btrfs RO snapshot prep, restore +
│                       # snapshots wrappers
└── disko.nix           # MODIFIED: bare-metal factory creates
                        # `persist` subvol + `root-blank` RO snapshot
                        # via postCreateHook unconditionally

scripts/
├── egghead.sh          # +IMPERMANENCE/BACKUP/IS_REINSTALL/SEED
│                       # prompts, collect_seed_users, emit_bridge
│                       # injects impermanence/backup imports + backup
│                       # overrides
└── host-setup.sh       # +do_install_backup_material (ssh-keygen +
                        # ssh-keyscan + password gen/reuse to
                        # /persist/etc/{restic,ssh-restic}/),
                        # +do_install_seed_users (nixos-enter +
                        # backup-restore --seed-from-user --seed-to-user)

packages/egghead/src/steps.tsx   # TUI mirror of new bash prompts

docs/runbooks/truenas-restic.md  # NAS-side one-time setup recipe
```

## Validation

`nix flake check --impure` passes for all five hosts. Synthetic
egghead run with `EGGHEAD_IMPERMANENCE=yes EGGHEAD_BACKUP=yes`
generated a `test-bare` bridge that builds end-to-end. pb-x1 with
impermanence + backup imports also builds (then reverted, since
the imports remain opt-in via egghead-emit until the operator
chooses to refresh that host).

## Next steps

1. Apply on the NAS (see `docs/runbooks/truenas-restic.md`).
2. Egghead-refresh pb-x1 (the most-customized host). Before
   pulling the trigger, take a one-shot manual restic backup
   against the existing pb-x1 (so the seed source exists). Then
   refresh with `IS_REINSTALL=yes` and the seeded restore should
   bring back ~/persist content.
3. Repeat for pb-t480.
4. Fresh-install m-pc.
