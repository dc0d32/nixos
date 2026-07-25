# 2026-07-25 — pb-x1 → pb-mb laptop handoff (state transfer)

## Why this exists
Switching primary laptop from **pb-x1** to **pb-mb** for a while. A long-running
Copilot session on pb-x1 (id `98d3c305`) had accumulated homelab context — old
inventory drafts, raw diagnostic dumps, a todos DB. This documents what is/was
transferable so nothing is lost, and so pb-mb can pick up where pb-x1 left off.
Belt-and-suspenders record in case both the transfer tarball and the cloud
session store are ever unavailable.

## What was already portable (no action needed)
- **Code + config**: both repos (`dc0d32/nixos` + `dc0d32/homelab` submodule)
  were clean and fully pushed. `git clone --recurse-submodules` on pb-mb gets
  everything.
- **pb-mb is already a flake host**: `flake-modules/hosts/pb-mb.nix` exists →
  buildable/activatable on day one (`home-manager switch --flake .#'p@pb-mb'`,
  `sudo nixos-rebuild switch --flake .#pb-mb`).
- **Curated homelab context is in git**: `homelab/inventory.md`,
  `homelab/design/*` (runbooks: p1-ursa, p2-andromeda, rehearsals, skeleton),
  `homelab/sessions/*`. The session-state `files/` drafts (network-inventory.md,
  andromeda-migration-prep.md, dmz-plan.md) were the working drafts that got
  distilled into these committed docs — content is safe in git.
- **Copilot memories** (homelab facts): server-side per GitHub account →
  auto-sync when logging into Copilot on pb-mb.
- **This conversation + checkpoints**: in the Copilot cloud session store →
  queryable from pb-mb under the same account.

## What was local-only (transferred out-of-band)
Local-only bits that are NOT in git and NOT guaranteed in the cloud store:
1. **Raw ursa/andromeda diagnostic dumps** (`files/raw/…` — live `compose-deep`,
   `pve`, `hw`, `drift`, `vmconf`, `truenas-tasks` captures). Unique point-in-time
   snapshots, ~29 KB text.
2. **Todos DB** (`session.db`) — 17 pending items (see below).
3. **plan.md** for the session.

Bundled (lean; **excluded** the 86 MB `events.jsonl` — conversation is in the
cloud) into `pb-x1-homelab-context.tar.gz` (~68 KB, sha256
`d343ad02385647b611af43b6c89acd537777fb6fd47bedeb8430b2253b5685e1`).
Secret-scanned first — clean (only docs *about* secret names, no values).

**Transfer channel** (operator's choice): pb-x1 → pushed to
`andromeda:/persist/transfer/` (persist-safe across reboots) → pb-mb pulls it
once over password-SSH:
```sh
scp root@192.168.10.10:/persist/transfer/pb-x1-homelab-context.tar.gz ~/
sha256sum ~/pb-x1-homelab-context.tar.gz   # d343ad02…
tar xzf ~/pb-x1-homelab-context.tar.gz -C ~/   # → ~/homelab-session-context/
ssh root@192.168.10.10 'rm /persist/transfer/pb-x1-homelab-context.tar.gz'  # cleanup shared box
```

## pb-mb setup checklist
1. `git clone --recurse-submodules https://github.com/dc0d32/nixos ~/nixos`.
2. Log into Copilot with the same GitHub account (memories + cloud sessions sync).
3. Retrieve + extract the context tarball (commands above).
4. **SSH for the agent to operate the homelab**: password-once is fine for the
   file grab, but agent-driven deploys want key auth. pb-x1 has NO default
   `id_*` key — it uses ssh-agent + deploy keys (`openwrt_deploy`,
   `rehearsal_deploy`, `nixtest_deploy`) and `~/.ssh/config` aliases
   `andromeda`/`ursa` → `User root`. On pb-mb: restore `~/.ssh` from the
   `/persist` home backup, or add pb-mb's key to the hosts' `authorized_keys`.

## Pending todos carried over (17)
- **Laptop-backup arc (now pb-mb-relevant)**: `restic-receiver-rebuild`
  (rebuild backup receiver on andromeda — laptops' backups broken), plus
  `pbx1-backup-{keygen,authorize,hostkey,password,test}`. On pb-mb this becomes
  the pb-mb backup setup.
- **Storage**: `nvme-repave-zssd` (DONE this arc — znvme hot-tier, see
  homelab/sessions/2026-07-19-nvme-znvme-hot-tier.md), `nvme-cleanup-retired`
  (delete retired browser-sandbox + orcaslicer docker dirs, ~9 G).
- **DNS**: `eval-technitium-dns` — decision: STAY on AdGuard-on-ares (parked).
- **Migration tails**: `mig-p3-harden`, `mig-p4-{nids,nomad,rootless}`.
- **draco**: `draco-{bastion-vpn,central-logs,serial-console}` (future/low).
- **UX**: `pbx1-clipboard-debug` (Chrome/terminal paste issue — retest on pb-mb).

## Other work in this session (context, already done)
- **NVMe znvme hot-tier + ARC 192 G** — committed/pushed (homelab 21b1d54,
  parent 4bbb860). See homelab/sessions/2026-07-19-nvme-znvme-hot-tier.md.
- **OpenWrt fleet flash** — ares + ap-1/2/3 sysupgraded to the new MX4300 image
  (kernel Jul 17); ap-4 (Archer) deliberately skipped. Backups saved to
  `~/Downloads/openwrt-backups/`. No repo change (external firmware build).
- **immich v3.0.2 → v3.0.3** — floating `v3` tag pull + recreate; 35,030 assets
  intact, migrations clean, no schema drift. Rollback guards kept:
  `pg_dumpall` PREUPGRADE dump on zrust + ZFS snapshot `znvme/immich@pre-v3.0.3`.
  No repo change (floating tag).

## Hard rules honored
No home-manager-into-NixOS, no dotfiles-repo split, no secrets framework, LF
endings. Commit/push here done only on explicit operator instruction.
