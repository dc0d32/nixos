# 2026-07-28 — cross-host timekpr controller (+ a `/bin/bash` detour)

Two things happened in this session. The second one is the real work; the
first one blocked it for an hour and is worth writing down because it will
recur on every host.

## Part 1 — the `/bin/bash` detour

### Symptom

Every `bash` tool call from the Copilot CLI agent failed instantly with
`Failed to start bash process`. Interactive `bash` in a terminal was fine
(`which bash` → `/run/current-system/sw/bin/bash`).

### Root cause

GitHub Copilot CLI 1.0.61 hardcodes the pty executable. In
`lib/github-copilot-cli/sdk/index.js`, the shell-session factory `Z4.create`:

```js
let u = l ? c : "/bin/bash",   // l = (shellType === "powershell")
    d = [...e.processFlags];   // bash default: ["--norc","--noprofile"]
h = g(u, d, { cols: p, rows: m, cwd: r, env: { … } });   // node-pty spawn
```

That string literal is the **only** occurrence of `/bin/bash` in the whole
package. There is no `$SHELL` fallback, no PATH lookup, and it isn't a
configurable field on the shell-config class — the sandboxed spawn path
`aEt(u, …)` receives the same `u`. NixOS ships only `/bin/sh`, so the
node-pty spawn ENOENTs, `this.process` stays undefined, and the wrapper
throws.

The nixpkgs wrapper prepends `bash-interactive` to `PATH` (visible in
`/proc/<pid>/environ`). That was sufficient for earlier releases. It is not
sufficient for 1.0.61, because PATH is never consulted.

Ruled out first: pty exhaustion (`nr=1`, `max=4096`), disk (26 GB free),
`ulimit` (generous), load (0.17).

### Fix

`flake-modules/bin-bash.nix` → `flake.modules.nixos.bin-bash`. An activation
script that does `mkdir -p /bin` plus an atomic
`ln -sfn ${pkgs.bashInteractive}/bin/bash /bin/.bash.tmp && mv …` — the same
shape as nixpkgs' own `binsh` script.

Deliberate choices:

- **No `deps = [ "binsh" ]`.** It does its own `mkdir -p /bin` so an upstream
  rename of the `binsh` activation script can't silently break it.
- **Runs on boot as well as on switch.** Necessary: the impermanence module
  rolls `/` back to `root-blank` in initrd, so a switch-only symlink would
  evaporate at the next reboot.
- **Does not relax the repo's shebang rule.** The `check-bash-shebang`
  pre-commit hook (`flake-modules/dev-shell.nix`) still rejects
  `#!/bin/bash`. `/bin/bash` now existing on our hosts is a compatibility
  shim for one vendored binary, not a licence to hardcode the path in repo
  scripts — those still run on hosts (and macOS) where it may be absent.

Imported by `bundles/nixos-workstation.nix` (⇒ pb-x1, m-pc, pb-t480) and by
`hosts/{wsl,nixtest,ah-1}.nix`. pb-mb is macOS/HM-only and already has
`/bin/bash`.

Homelab submodule hosts (ursa, andromeda, draco) are **not** wired yet: they
consume `pub` pinned to `github:dc0d32/nixos`, so they can only pick this up
after the public flake is pushed and the `pub` input bumped.

Retirement condition is in the module header: delete it when the CLI resolves
bash from `PATH`/`$SHELL`.

## Part 2 — one shared screen-time budget across hosts

### The ask

`m` and `s` each get **one** daily screen-time budget that is spent across
whichever machines they use (today: pb-t480 for both, m-pc for `m`), rather
than a fresh per-host allowance on each. Controller hosted on ursa.

### What was already there, and why it did nothing

`flake-modules/timekpr.nix` (per-host daemon + declarative policy) worked.
`flake-modules/timekpr-sync.nix` — a bash agent — did not, for five separate
reasons:

1. It read `/var/lib/timekpr/work/timekpr.<u>.time`. Upstream writes
   `<workdir>/<user>.time` (`common/utils/config.py`:
   `os.path.join(pDirectory, "%s.time" % (pUserName))`). Because the read was
   behind a `[ -f ]` guard, the agent **silently no-opped for its entire
   life**. No logs, no alarm.
2. `options.timekpr-sync` was declared at the flake-parts **top level** while
   *both* host bridges set `serverUrl` — i.e. two hosts writing one option.
   It only evaluated because `types.str` merges byte-identical definitions.
   Changing either host's URL would have broken the flake.
3. It pointed at `apphost.lan`, a host retired months ago.
4. It re-applied `--settimeleft` unconditionally every 60 s, which rewrites
   the control file, which makes the daemon reload and fire
   `timeLeftChangedNotification` — a tray popup, once a minute, forever.
5. No staleness check on the work file: yesterday's leftover
   `TIME_SPENT_DAY` would be reported as today's usage in the window before
   the daemon resets it.

Separately: `/var/lib/timekpr` was **not** in the impermanence persistence
list, and both kid hosts import impermanence. Usage counters reset on every
reboot. That is a one-keystroke bypass and was the most serious finding of
the session.

### Upstream semantics that make this design possible

Verified against timekpr-nExT source rather than assumed:

- Work file `/var/lib/timekpr/work/<user>.time`, INI, section `[<user>]`,
  keys `TIME_SPENT_DAY`, `TIME_SPENT_BALANCE`, `LAST_CHECKED`
  (`%Y-%m-%d %H:%M:%S`).
- Config `/var/lib/timekpr/config/timekpr.<user>.conf`, section `[USER]`,
  `LIMITS_PER_WEEKDAYS = s1;…;s7`, ISO order (mon = index 0, matching
  `datetime.weekday() == 0`).
- Enforcement is `time_left = LIMITS_PER_WEEKDAYS[today] - TIME_SPENT_BALANCE`
  (`server/user/userdata.py`).
- **`timekpra --settimeleft <u> = <sec>` sets `TIME_SPENT_BALANCE =
  limit_today - sec` and never touches `TIME_SPENT_DAY`**
  (`server/config/configprocessor.py::checkAndSetTimeLeft`).

That last point is the load-bearing one. It means `TIME_SPENT_DAY` remains a
**pristine local measurement** even after the controller writes back a
budget. So the agent can report `TIME_SPENT_DAY` and apply the controller's
answer via `--settimeleft` with **no feedback loop** — the thing we measure
and the thing we write are different fields. Had `--settimeleft` moved
`TIME_SPENT_DAY`, the whole architecture would have been circular and we'd
have needed a shadow counter.

### Design

Agent (per host, `timekpr-sync.py`, stdlib only):

1. Read `TIME_SPENT_DAY` for each managed user; report `0` if `LAST_CHECKED`
   is not today (staleness guard, fixes bug 5).
2. `POST /report` to the controller with `(host, user, spent)`.
3. Compare the controller's `remaining` against local
   `limit_today - TIME_SPENT_BALANCE`.
4. Apply `timekpra --settimeleft <u> = <remaining>` **only** if they differ by
   more than a tolerance (default 60 s) — so a single-host day makes roughly
   zero writes and zero notifications (fixes bug 4).
5. Clamp the applied value to `limit_today + maxExtraMinutes`.

Controller (ursa, `timekpr-central.py`, stdlib only — `http.server` +
`sqlite3`):

- Stores usage **monotonically**: `max(stored, reported)` per
  `(host, user, day)`.
- `remaining = max(0, budget(day) + grants - Σ consumed across all hosts)`.
- `GET /` parent dashboard (HTML), `GET /status` (JSON), `POST /grant`
  (bonus/penalty minutes for a given day), `POST /lock` / `POST /unlock`,
  `GET /health`.

### Lock

A parent-initiated "off, now, everywhere". Deliberately **not** per-day and
**not** per-host: it lives in its own `locks` table keyed only by username,
so it survives midnight, a controller restart, and moving to the other
machine. `until` is NULL for indefinite or a timestamp for a timed lock
(the dashboard offers Lock / Lock 30m / Lock 2h); expired and unparseable
values self-clear on read, because the one thing worse than a lock that
doesn't stick is a lock that can't be lifted.

Locked users report `remaining: 0` in the payload itself, not just a
`locked` flag, so even an agent that predates this feature does the right
thing. The agent then:

- forces the target to `0`, **bypassing the `maxExtraMinutes` clamp** — that
  clamp exists to stop a hostile server *granting* time, so it has no
  business standing between a parent and a lock;
- skips the tolerance gate, so the lock is re-asserted on every poll and
  survives the kid logging back in;
- runs `loginctl lock-session` for each of the user's sessions.

The zeroed budget is the real enforcement — timekpr then applies the host's
configured `lockoutType` exactly as it would at natural end-of-budget.
`loginctl` is only there so the screen goes *now* rather than on the
daemon's next tick; it's best-effort and its failure changes nothing.

**`lockoutType` is `lock`, not the `terminate` default.** The default
SIGTERM/SIGKILLs the session the moment the budget or a curfew boundary is
hit, which destroys unsaved work as a matter of routine, several times a
week. Verified `lock` actually works on these hosts before switching:
timekpr calls the logind session's `.Lock()`
(`server/interface/dbus/logind/user.py::lockUserSessions`), gated on the
session `Type` being one of `x11;wayland;mir` — a niri session reports
`wayland`, so it matches — and swayidle's `lock` event handler is already
listening for that signal and raises swaylock-effects
(`flake-modules/idle.nix`). Same D-Bus method the agent's
`loginctl lock-session` uses, so both paths converge.

This doesn't weaken enforcement. Unlocking with their password returns them
to a daemon that still sees zero time left, which re-locks on its next poll.
And `TRACK_INACTIVE = False` means a locked screen stops consuming budget,
so a lock can't quietly eat into the next day either.

### Decisions worth remembering

**Monotonic `max()` is the primary anti-tamper control, not the token.**
A kid who discovers the endpoint can only ever report a *higher* number.
Replaying a low value does nothing. The bearer token is hardening on top;
that's why `/report` stays open when no token file is configured — a broken
token shouldn't silently disable enforcement.

**Dashboard auth fails closed.** `adminPasswordFile` defaults to `""`, and
while no password file exists the dashboard and `/grant` return 503 rather
than serving unauthenticated. The dashboard hands out screen time, and the
adversary is on the same LAN with a laptop we administer. Serving it open
"until I get around to the password" would be strictly worse than it being
down.

**Auth lives in the app, not in Caddy.** The edge vhost
(`screentime.bitset.cc`) is `expose = "lan"`, which emits Caddy's
`not remote_ip private_ranges` → 403 guard. That keeps the internet out but
explicitly does *not* keep the kids out — they are RFC1918 clients on the
trusted VLAN, and so is anything on the guest VLANs, which `dmz.nix` also
lets reach the edge. And `192.168.10.11:8780` is reachable directly on the
LAN regardless of what the proxy does. So proxy-level auth would have been
theatre; the controller does its own.

**The report token is in git, and that is correct.** It authorizes exactly
one operation — "record usage for (host, user)" — and usage is stored as
`max(stored, reported)`. So the only thing a holder can do is make a kid's
day *shorter*. There is no reachable state where knowing it buys anyone time.
It also *could not* be a secret: it is baked into the agent's spec file in
`/nix/store`, which is world-readable on the kids' own laptops. A `tokenFile`
would only have moved the same string somewhere slightly less obvious while
adding per-host provisioning. It lives in `flake.lib.timekprCentral`
alongside the controller URL so the hosts and ursa can't drift.

The credential that *does* matter — the dashboard password, which is what
gates granting time — stays out of git in `/persist/secrets`.

**Agents talk to `https://screentime.bitset.cc`, not the LAN IP.** This is a
security improvement, not just tidiness. Over plain HTTP to `192.168.10.11`,
a kid on the LAN could ARP-spoof the controller and forge a reply worth
`maxExtraMinutes` of free time. Against the edge's real wildcard certificate
they can't. AdGuard rewrites `*.bitset.cc` to the DMZ edge, so the name works
from any VLAN; off-LAN it resolves publicly, the LAN guard 403s, and the
agent no-ops.

**Killed an auth footgun while we were in there.** `homelab.edgeProxies.*.auth`
accepts `"basic"` in its enum, but `mkVhostConfig` in
`flake-modules/homelab/stacks.nix` only ever emits the lan guard and the
authentik forward-auth block. Setting `auth = "basic"` produced a vhost with
**no authentication at all** — silently. Nothing in the repo used it. Added
an assertion that rejects it with an explanation. A silent no-op is the worst
possible failure mode for a security knob; better to refuse to build.

**Options must be declared inside the NixOS module.** The private homelab
flake consumes `pub.modules.nixos.*` as an already-evaluated attribute, so
flake-parts-level `options.<ns>` declarations are invisible to it. Both
`timekpr-central.nix` and the rewritten `timekpr-sync.nix` declare their
options inside the module body. This also fixes bug 2 above as a side effect
— per-host settings are now per-host.

**Budgets have exactly one source of truth.** ursa reads
`pub.lib.kidTimekprPolicy.dailyBudgetMinutesByDay` (published by
`flake-modules/kid-hm.nix`), the same attrset the local per-host timekpr
policy uses. The shared budget and the local fallback cap can't drift.

**Failure mode is degradation, not bypass.** Controller down, or laptop off
the LAN → the agent no-ops and the host falls back to its own local per-host
cap, which is exactly today's behaviour. A hostile controller handing out
`remaining: 999999` gets clamped to `limit_today + maxExtraMinutes`.

### A bug I introduced and fixed

`/report` initially returned 401 without reading the request body. With
`protocol_version = "HTTP/1.1"` (keep-alive), the unread body stayed in the
socket buffer and got parsed as the *next* request line —
`code 400, Bad request syntax ('host=pb-t480&user=m&spent=3600')`. Classic
connection desync.

Fix: `_drain_body()` is called **before dispatch** in both `do_GET` and
`do_POST`, capped at 64 KiB, cached on `self._body`, and reset per request via
a `handle_one_request` override. Note *not* in `__init__` — with keep-alive a
single handler instance serves many requests, so per-instance init would have
leaked one request's body into the next.

### Tested

End-to-end against live processes, not just eval:

- Cross-host sharing: `m` uses 1 h on pb-t480 + 2 h on m-pc against a 4 h
  budget → agent pulls the laptop down to 1 h (`--settimeleft m = 3600`).
- Convergence: the next run makes **no** `timekpra` call. No notification
  spam.
- Anti-rewind: replaying a lower `spent` does not reduce stored usage.
- Stale work file (yesterday's `LAST_CHECKED`) → skipped.
- Controller down → agent no-ops, no `timekpra` call.
- Hostile `remaining: 999999` → clamped to 18000 (cap 14400 + extra 3600).
- Overspend → `remaining` floors at 0, never negative.
- State survives a controller restart.
- Lock/unlock refuse both no-auth and report-token-only requests (401); only
  the parent's basic auth works.
- Locked → `--settimeleft 0` + `lock-session`, re-asserted on a poll where
  the local remainder is already 0 (so a re-login doesn't escape it).
- Unlock → next poll restores the pooled remainder.
- Timed lock past its `until`, and a corrupted `until`, both self-clear.

Plus `nix fmt .`, `nix flake check --impure`, toplevel builds for pb-t480 and
m-pc, and — for ursa — the controller unit, the generated config JSON, the
vlan10-only firewall hole for 8780, and the rendered `screentime.bitset.cc`
vhost.

### Known blockers for the deploy

1. **`pub` is pinned.** ursa can't get the controller until the public flake
   is pushed and the homelab's `pub` input bumped. Same blocker as the
   `bin-bash` wiring for homelab hosts.
2. **Stale caddy vendor hash.** Building ursa against the newer nixpkgs that
   a `pub` bump drags in fails with a `caddy-src-with-plugins` fixed-output
   hash mismatch. Confirmed pre-existing and unrelated — the identical
   failure reproduces with all of this session's edits stashed. It will need
   re-pinning as part of the bump.
3. **One secret, one host.** `/persist/secrets/timekpr-dashboard.pass` on ursa
   (0600, root) — and that is the whole provisioning story. The controller
   stays 503 until it exists, by design. The agents' report token is in git,
   so the kid hosts need nothing hand-placed.
4. **~~`timekpr.nix` uses `C` (copy-if-missing) tmpfiles semantics~~ — FIXED,
   see the postscript below.** This entry originally claimed both kid hosts
   were placeholders so a fresh install would pick up the new policy. That
   was wrong on both counts and is corrected in the postscript.

## Postscript: timekpr was never enforcing anything

Written after the user reported: *"both m-pc and t480 are live of course, and
kids use them every day. When they log in, timekpr says no time limit set for
today."*

That message is timekpr's `TK_MSG_NOTIFICATION_NOT_LIMITED`. Tracing it back
produced the real finding of this session: **the `timekpr` module has never
applied a single limit since it was written.** Two independent bugs, each of
which alone would have been enough.

### Bug 1 — wrong INI section name

`renderUserConf` emitted `[USER]` / `[USER.PLAYTIME]`. timekpr reads the
section named after the *user*:

```python
# timekpr/common/utils/config.py :: loadUserConfiguration
section = self._userName          # -> "[m]", not "[USER]"
```

Every parameter read therefore raised `NoSectionError`. That exception is
swallowed by `_readAndNormalizeValue`, which substitutes `pDefaultValue`
without failing the load. The defaults are the permissive ones:

| parameter | default substituted |
| --- | --- |
| `LIMITS_PER_WEEKDAYS` | `86400` × 7 (24 h/day) |
| `ALLOWED_HOURS_<n>` | `0;1;…;23` (all day) |
| `LOCKOUT_TYPE` | `terminate` |

`server/user/userdata.py` sets `TK_CTRL_TNL = 1` when the day limit is
`>= 86400` *and* the allowed intervals cover `>= 86400` seconds — which is
exactly what those defaults produce. Hence "Your time is not limited today".

Worse, the tail of `loadUserConfiguration` does:

```python
if not resultValue:
    self.initUserConfiguration(True)   # save what we could read + defaults
```

so the daemon **rewrote the file** with the correct `[m]` section carrying the
unlimited defaults, permanently destroying the declared policy.

Verified by A/B-ing both files through timekpr's own loader:

```
=== fixed, [m] ===             === buggy, [USER] ===
LIMITS: 14400 … 21600          LIMITS: 86400 × 7
hours mon: 6..21               hours mon: 0..23
LOCKOUT_TYPE: lock             LOCKOUT_TYPE: terminate
"not limited"?  False          "not limited"?  True
file NOT rewritten             FILE REWRITTEN -> [m] with unlimited defaults
```

### Bug 2 — the fix could never have reached the live hosts

Seeding used `systemd.tmpfiles` `C`, i.e. *copy only if the destination is
missing*. Because bug 1 caused the daemon to write an unlimited config on
first boot, that file existed — so correcting the renderer alone would have
changed nothing on m-pc and pb-t480, forever, silently.

This is the same failure mode as the two earlier silent no-ops in this
subsystem (the old shell agent's wrong `.time` filename behind a `[ -f ]`
guard, and the agent's own inherited `[USER]` bug, found in the same pass).
The pattern is consistent: **every layer here failed open and said nothing.**

### The fix

- `renderUserConf` emits `[<username>]` / `[<username>.PLAYTIME]`.
- `timekpr-sync.py::local_limit_today` reads section `<username>`, not
  `USER` — it had inherited the same bug and would have returned `None` for
  every user, making the whole controller a no-op too.
- Seeding moved from tmpfiles `C` to `timekpr-seed-config.service`, which
  compares the seed's **store path** against a `/var/lib/timekpr/config/
  .seed-<user>` stamp and re-copies only when the *declared* policy changes.
  So: a policy edit + `nixos-rebuild switch` now actually applies, while
  ad-hoc `timekpra` adjustments still survive reboots. `restartTriggers` on
  both the seed unit and `timekpr.service` make a switch take effect without
  a reboot.
- The live hosts self-heal on the next switch: they have no stamp file, so
  the corrected config is written unconditionally. No manual `rm` needed.

Behaviour verified against a simulated live host (daemon-rewritten unlimited
`[m]` config, no stamp): run 1 repaired it, run 2 was a no-op, and a
simulated runtime `timekpra` edit was preserved across a third run.

### Also corrected

`flake-modules/hosts/m-pc.nix` carried `placeholder = true` with a comment
claiming its hardware config was the all-zeros sentinel. It is not — it is a
genuine `nixos-generate-config` output for an Intel desktop, and the machine
is a daily driver. The stale marker forced `NIXOS_ALLOW_PLACEHOLDER=1` on
every rebuild of a live host. Now `false`; `nix build
.#nixosConfigurations.m-pc.…toplevel` succeeds with no env var.
(`pb-t480` was already `false`.)

### Removed

`scripts/timekpr-central/` (FastAPI + docker-compose + Dockerfile) — a manual
control plane that was never deployed anywhere. Superseded by the native
module.

### Follow-up: two more silent-failure bugs in the same module

Prompted by the user asking "does that also mean that if I login on those
machines, I won't be limited? What about similar messages on pb-x1?"

**pb-x1 is clean.** It never imported the module. Verified on the live
machine: no `timekpr*` binary on PATH, no units, no `/var/lib/timekpr`, no
autostart entry, no running process. Nothing to remove.

**Bug 8 — the admin account was being enrolled.** The shipped
`/etc/timekpr/timekpr.conf` excludes only display managers:

```
TIMEKPR_USERS_EXCL = testtimekpr;gdm;kdm;lightdm;mdm;lxdm;xdm;sddm;cdm
```

`server/interface/dbus/daemon.py` enrolls *every* valid non-excluded user
that logs in, and calls `initUserConfiguration()` for unknown ones. So
logging in as `p` on m-pc/pb-t480 auto-wrote an unrestricted
`timekpr.p.conf`. Not limited — but tracked, complete with tray icon and
notifications, and one mis-click in the timekpra admin GUI away from
limiting the admin account on the machine needed to undo it.

Added `timekpr.excludeUsers`, set to `[ primaryUser ]` on both kid hosts.
The main config is now produced by `sed`-ing the shipped file's
`TIMEKPR_USERS_EXCL` line rather than being rewritten wholesale — every
other upstream key (including keys a future release adds) survives
untouched, which matters because the file sits in the read-only store and a
missing key makes the daemon try to write it back. A `grep -q` guard fails
the build if upstream ever renames the key, rather than silently dropping
the exclusion. Both directions of that guard were tested.

**Bug 9 — `options.timekpr` was declared at the flake-parts top level.**
That makes it one option shared by the entire flake, so every host setting
`timekpr.users` merged into the same attrset and all of them received the
union. Concretely: **m-pc was seeding a `timekpr.s.conf` for user `s`, who
does not exist on m-pc**, purely because pb-t480 declares `s`. It also made
per-host policy divergence impossible. The `;p;p` in a first render of
`TIMEKPR_USERS_EXCL` (two hosts each appending `primaryUser` to one shared
`listOf`) is what exposed it.

This is the same defect already noted for `timekpr-sync`, which went
unnoticed only because `types.str` silently merges byte-identical
definitions. Options moved inside the NixOS module, matching
`timekpr-central` and `timekpr-sync`. The host bridges now set
`timekpr.users` / `timekpr.excludeUsers` inside
`configurations.nixos.<host>`.

Verified per-host isolation after the move:

```
m-pc     seeds: timekpr.m.conf                     EXCL: …;cdm;p
pb-t480  seeds: timekpr.m.conf timekpr.s.conf      EXCL: …;cdm;p
```

That is nine silent failures in one subsystem. Every layer — the daemon's
config reader, tmpfiles `C`, the old shell agent's `[ -f ]` guard, and
flake-parts' option merging — failed open and reported nothing. Worth
remembering when reviewing anything else in this repo that "works" without
ever having been observed to produce an effect.

### Audit: other cross-pollution from top-level options

Prompted by "look for other similar cross-pollution issues". The defect in
bug 9 is not timekpr-specific — AGENTS.md documents top-level
`options.<ns>` as the house pattern, and it is only safe when exactly one
host ever sets the namespace.

Two scans were run: every `options.*` declaration in the repo classified by
whether it sits at the flake-parts top level or inside a module body, and a
script grouping every indent-2 assignment across `flake-modules/hosts/*.nix`
by attribute path to flag any set by more than one host.

**Clean:**

- `homelab/nix/*.nix` (`homelab.alerting`, `homelab.kuma`,
  `homelab.idracMonitor`, `homelab.storageHealth`,
  `services.selkiesDesktop`) — plain NixOS modules, not flake-parts. Already
  per-host.
- `audio`, `displays`, `hardware-hacking.extraUsers`, `users.primary`,
  `homelab.{domain,registry}` — options already declared inside module
  bodies. `displays.nix` even carries a comment explaining the hazard and
  why `displays.outputs` is declared inside the HM module.
- `configurations.{nixos,homeManager}`, `flake.lib` — genuinely global,
  keyed by host/config name. Working as intended.
- `biometrics.face` — declared inside the NixOS module, set by
  `face-unlock.nix` inside its own module. Per-host.
- `git`, `locale`, `nixos-clone`, `wallpaper` — top-level, but set by no
  host. Latent only.
- Most multi-host indent-2 hits (`hostName`, `system`, `user`,
  `stateVersion`, `kidUsers`, `hmPkgs`, `audioCfg`, `central`, …) are
  `let` bindings, file-scoped, not options.

**Fixed — `chrome-managed.policyFile`.** Top-level, and set by both m-pc and
pb-t480. Its own header claimed "Different hosts could ship different policy
files by setting `chrome-managed.policyFile` differently" — false. Two
differing paths would have been a `conflicting definition` error on a
`nullOr path`; it only looked fine because both hosts set the byte-identical
path. Moved inside the NixOS module. Verified afterwards that divergence now
actually works: pointing m-pc at a different file yields different store
paths per host instead of an eval error, and pb-x1 (which does not import
the module) still gets no policy at all.

**Documented, not fixed — `bluetooth.enable` / `biometrics.enable`.** These
are the "cross-module signal" pattern from AGENTS.md, and both are broken in
the same direction: the `mkDefault true` is applied at the flake-parts top
level, and import-tree loads every file unconditionally, so **the flag reads
`true` on every host in the flake** — including wsl and ah-1, which never
import bluetooth. The claim "true iff this module is imported on this host"
was false in both file headers and both option descriptions.

Not fixed because it cannot be fixed by relocation: the intended consumer
(waybar's bluetooth chip) is home-manager, HM runs standalone here, and a
NixOS module's config is invisible to an HM evaluation. A real cross-class
per-host signal needs a different mechanism. Impact today is nil — nothing
reads either flag, and the waybar chip is unconditional — so the headers and
descriptions were rewritten to state the actual semantics and warn against
gating on them. Worth revisiting if a consumer is ever wanted.
