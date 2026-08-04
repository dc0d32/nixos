# Auto-update — how hosts keep themselves current

**One sentence:** every non-homelab NixOS host polls roughly hourly for
a good moment — awake, on wall power, online, and either inside a quiet
window or overdue — and when it finds one it rebuilds the system from
`github:dc0d32/nixos` and then re-activates *every* user's
home-manager profile, in that order.

Everything below is implemented in four files:

| file | role |
| --- | --- |
| `flake-modules/auto-update.nix` | the driver: timer, gate, sequencing, status CLIs, all `autoUpdate.*` options |
| `flake-modules/auto-upgrade.nix` | `nixos-auto-upgrade.service` — the system rebuild |
| `flake-modules/hm-auto-upgrade.nix` | `hm-auto-upgrade.service` — every user's home-manager profile |
| `flake-modules/power-gate.nix` | `ac-check`, the shared "are we on wall power?" probe (also used by backup) |

They ship as one bundle, `flake.lib.bundles.nixos.auto-deploy`
(which also pulls in `nixos-clone`, the per-user `~/nixos` checkout).

---

## Which hosts

| host | what it is | auto-updates | HM profiles activated |
| --- | --- | --- | --- |
| `pb-x1` | ThinkPad X1 Yoga, primary dev laptop | yes | `p` |
| `pb-t480` | ThinkPad T480, shared family laptop | yes | `p`, `m`, `s` |
| `m-pc` | desktop | yes | `p`, `m` |
| `wsl` | NixOS in WSL2 (x86_64) | yes | `p` |
| `wsl-arm` | NixOS in WSL2 (aarch64) | yes | `p` |
| `pb-mb` | MacBook Air (macOS) | **no** | — |

`pb-mb` is a standalone home-manager config on macOS — there is no NixOS,
no systemd, and no `nixos-rebuild`. It updates when you run
`home-manager switch --flake .#'p@pb-mb'`.

**A host that is still on a placeholder `hardware-configuration.nix`
must not be given this bundle.** `nixos-rebuild --flake github:…`
evaluates purely, where `builtins.getEnv` returns `""`, so the
placeholder assertion can never pass and every run aborts — silently,
because the unit failing looks the same as a host that is simply off.
The retired `ah-1` did exactly this for months. See AGENTS.md >
"Placeholder hosts".

The homelab (`homelab/` submodule: ursa, andromeda, draco, …) is a
separate flake with its own deploy story and is **not** covered here.

A host opts in purely by importing the bundle in its bridge — there is
no `enable` flag:

```nix
++ config.flake.lib.bundles.nixos.auto-deploy
```

---

## What actually runs, in order

```
auto-update.timer          OnBootSec=10min, OnUnitActiveSec=1h, jitter 10min
        │
        ▼
auto-update.service        ExecCondition = auto-update-gate   ← decides "now?"
        │                  ExecStart     = auto-update-run     ← sequencer
        │
        ├─(1)─► nixos-auto-upgrade.service      [required]
        │         nixos-rebuild switch --refresh \
        │           --flake github:dc0d32/nixos#<host>
        │
        └─(2)─► hm-auto-upgrade.service         [required]
                  for each <user>@<host> in homeConfigurations:
                    nix build --refresh …activationPackage
                    runuser -u <user> -- env … $out/activate
```

**Required vs best-effort.** A failing *required* step fails the run and
withholds the `last-success` stamp, so the 24h staleness fallback keeps
retrying. A failing *best-effort* step is logged loudly and recorded in
the status file but doesn't block anything. Nothing currently uses the
best-effort class; it exists so that convenience work can be added later
without being able to wedge the updater.

## `~/nixos`, the hand-deploy fallback

`~/nixos` is what you reach for **when auto-update has failed** — the
checkout you activate from by hand. That makes its delivery path
load-bearing, and it must not share fate with the thing it rescues you
from. So `nixos-clone-<user>.timer` is completely independent of
everything above: `OnBootSec=2min`, then `OnCalendar` hourly, ungated.

An earlier revision retried it from the auto-update sequencer instead,
which was circular — every condition that stops auto-update (battery,
outside the window, inside the 6h throttle, offline, or simply broken)
would also have stopped the clone. To force one right now:

```sh
sudo systemctl start nixos-clone-<user>.service
```

Coverage is the **bare-metal** hosts only — it ships in the
`workstation` bundle, not `auto-deploy`, because its applicable set is
"machines someone sits down at and may need to deploy from by hand":

| host | clone timers |
| --- | --- |
| `pb-x1` | `p` |
| `pb-t480` | `p`, `m`, `s` |
| `m-pc` | `p`, `m` |
| `wsl` / `wsl-arm` | — (created by the WSL install procedure) |
| `pb-mb` | — (`git clone … ~/nixos` is step 2 of the macOS bootstrap, since the first `home-manager switch` needs it) |

Cost after the first success is nil — `ConditionPathExists=!~/nixos/.git`
skips the unit in microseconds.

The unit has three explicit outcomes: already a repo → exit 0 "nothing
to do"; absent or empty → clone; non-empty without `.git` → exit 1 with
a message naming the path and the manual command. (The empty case is
normal, not exotic: hosts with impermanence pre-create `~/nixos` as an
empty bind mount, since `"nixos"` is in the persisted `userDirectories`.)

Deleting `~/nixos` now gets it recreated within the hour. To keep a
checkout elsewhere, leave a `.git` at the default path or drop the
module from the host.

**The checkout is never the source of an automatic upgrade.** Both real
steps fetch `github:dc0d32/nixos` into the nix store as root, so a dirty
or stale `~/nixos` cannot affect what gets deployed. Nothing ever pulls,
fetches or resets an existing checkout — your working tree is safe.

### Triggering a deploy by hand

Preferred, because it can't be stale and it does system *and* every
user's home-manager in the right order:

```sh
sudo auto-update-now
```

From the local checkout instead (note: only as current as your last
`git pull`):

```sh
cd ~/nixos && git pull
sudo nixos-rebuild switch --flake .#<host>
home-manager switch --flake .#'<user>@<host>'
```

Order matters: home-manager activates **after** the system switch, so it
lands on top of the freshly-rebuilt system closure rather than the
previous generation. The sequencer runs each step with
`systemctl start --wait`, which is what enforces that without either
step owning a timer.

The step list is not hardcoded in the sequencer — each feature module
registers itself into `autoUpdate.steps` with an explicit `lib.mkOrder`
(100 for the system, 200 for home-manager), so the order is a property
of the code rather than of module import order.

---

## The gate: when is "a good moment"?

`auto-update.service` uses systemd's `ExecCondition=`, not
`ExecStartPre=`. That distinction is the whole design: a failed
`ExecCondition` leaves the unit **inactive**, not **failed**. A poll that
decides "not now" is silent and normal; a unit in `failed` state always
means something is genuinely broken.

Five checks, in order:

**(a) Minimum interval — default 6h since the last attempt.** The rate
limit, and it is load-bearing rather than a nicety: the quiet window is
seven hours wide and the timer polls hourly, so without it any host awake
overnight would run the whole sequence ~7 times a night, and a host with
a persistently failing step (which never advances `last-success`) would
run a full `nixos-rebuild switch --refresh` every hour, forever, with no
backoff. The stamp is written by the *gate* when it decides to proceed,
not by the sequencer when it finishes, so a run killed by
`TimeoutStartSec` or by a shutdown mid-switch still counts against it.

**(b) Quiet window — default 02:00–09:00 local.** Inside it, go. The
morning edge is deliberately late: a laptop suspended overnight gets
opened somewhere between 07:00 and 09:00, and *that wake* is the
realistic opportunity to update it.

**(c) Staleness fallback — default 24h.** Outside the window, go anyway
if the last *successful* run was more than 24h ago. This is the piece
that keeps a machine only ever used 09:00–23:00 from never updating at
all. Without it, the quiet window is a trap. The stamp lives in
`/var/lib/auto-update/last-success` and is persisted through
impermanence, so it survives the root-subvol wipe on reboot.

**(d) Wall power.** `ac-check` (below). On battery → skip. Undeterminable
→ proceed with a warning, because a machine whose power state can't be
read but never updates is worse than one that occasionally updates on
battery.

**(e) Reachability.** Bounded poll (default 120s) of `github.com`. No
network → skip; don't burn a run on a rebuild whose fetch is going to
fail. The probe explicitly passes
`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` — a systemd service
inherits none of the session variables NixOS sets for interactive
shells, so without it curl fails CA verification on *every* poll and the
host silently never updates. If the CA bundle is missing for any reason
the probe degrades to a plain TCP connect rather than failing closed.

Plugging the charger in is also a trigger: a udev rule pokes
`auto-update.service` when a Mains supply goes online, so "plug in at
08:50" starts an update within seconds instead of at the top of the next
hour. The gate still runs, so a poke outside the window is a no-op, and
(a) means unplug/replug cycling can't turn into a rebuild storm.

**No `WakeSystem=true`.** A laptop in a bag stays asleep — waking a
machine to update it is how you cook a laptop in a backpack. The timer is
monotonic (systemd monotonic timers run off `CLOCK_BOOTTIME`), so suspend
time counts against it and a machine that wakes after a long sleep fires
promptly rather than waiting for a calendar slot it already missed.

---

## Power detection, including WSL

`ac-check` (`flake-modules/power-gate.nix`) resolves in three tiers:

1. **sysfs.** Scan every `/sys/class/power_supply/*` and read its
   `type`. `Mains` *and* `USB*` count as line power, because a laptop
   that only charges over USB-C exposes
   `ucsi-source-psy-USBC000:001` with `type=USB` and may have no `AC`
   node at all. Battery present + no line power online → on battery.

   Nodes with `scope=Device` are skipped. Bluetooth mice, keyboards,
   headsets, gamepads and Wacom pens all publish `type=Battery`, and
   counting them as a system battery makes a *desktop* report BATTERY
   the moment a peripheral pairs — an intermittent "silently stops
   updating and backing up" that depends on what happens to be
   connected.

   A system battery with no readable line-power node at all returns
   *undeterminable* rather than falling through to the desktop branch:
   a machine that demonstrably has a battery should not be assumed to be
   on wall power.
2. **WSL.** WSL2's kernel exposes **no** `power_supply` class at all —
   the VM has no virtual battery, so tier 1 finds nothing. If we're
   clearly inside WSL, ask Windows over interop:

   ```
   powershell.exe -NoProfile -NonInteractive -Command \
     "Add-Type -AssemblyName System.Windows.Forms; \
      [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus"
   ```

   which returns `Online` / `Offline` / `Unknown` and needs no
   elevation (unlike `root\wmi`'s `BatteryStatus` class).

   The catch: a systemd **system** service inherits no `WSL_INTEROP`, and
   without it the binfmt handler refuses to launch a `.exe`. So
   `ac-check` recovers the most recently created per-session interop
   socket from `/run/WSL/*_interop` and exports it first. If there is no
   session at all (nothing to inherit from), it returns "undeterminable"
   and the update proceeds — a WSL distro with no open session isn't
   costing anyone battery anyway.
3. **Neither.** No battery and no line-power node and not WSL → a
   desktop, VM or server. Always "on AC". This is what makes `m-pc` and
   `m-pc` unconditional.

Exit codes: `0` on wall power, `1` on battery, `2` undeterminable.
`ac-check --verbose` prints its reasoning, which is what lands in the
journal.

---

## Home-manager: all users, every time

Standalone home-manager is a deliberate architectural choice here (it
lets the same user modules apply on macOS), and the direct consequence is
that a system rebuild does **nothing** to anyone's dotfiles. So a
separate step activates them.

The user set is discovered, not configured: every
`homeConfigurations.<user>@<thishost>` in the flake. On `pb-t480` that is
`p`, `m` and `s` — adding a kid account to the host bridge automatically
adds them here, to `nixos-clone`, and to `home-manager-bootstrap`, with
no list to forget.

Per user:

1. `nix build --refresh …activationPackage` **as root** (one shared
   download; the store path is world-readable).
2. Compare against that user's current generation
   (`~/.local/state/home-manager/gcroots/current-home`). Equal → skip.
   Keeps hourly polling cheap and the journal readable.
3. `runuser -u <user> -- env … $out/activate`.

Three details of step 3 are load-bearing, and two of them are why "not
all users update" used to happen silently:

- **`USER` / `LOGNAME` / `HOME` are set explicitly**, and `HOME` comes
  from `users.users.<user>.home` rather than a hardcoded `/home/<user>`.
  home-manager's `activate` ends with `checkStringEq USER …` and
  `checkPathEq HOME …` and hard-exits 1 on mismatch.
- **`XDG_RUNTIME_DIR` + `DBUS_SESSION_BUS_ADDRESS` are passed when the
  user has a live session** (`/run/user/<uid>` exists). Without them the
  `systemctl --user` calls inside HM activation can't reach the user's
  systemd manager, so a logged-in user's waybar / mako / cliphist keep
  running the *old* config: the activation "succeeds" while visibly
  changing nothing. With no session, the journal says so and the new
  units start at next login.
- **Source is always `github:dc0d32/nixos`, never the user's `~/nixos`
  clone.** Activating from a working tree couples upgrades to whatever
  state the user left it in (dirty, on a branch, stale fetch).

---

## Graceful fallback, at every layer

| situation | behaviour |
| --- | --- |
| machine asleep / powered off | monotonic timer; fires promptly on wake or 10min after boot. No missed-calendar-slot to catch up on. |
| run killed mid-switch (timeout, shutdown) | the attempt was stamped by the gate *before* the run, so it still counts against the 6h throttle — a host that can never finish a run doesn't retry forever. |
| on battery | gate skips, unit stays `inactive`. Retries next hour, or the moment you plug in (udev). |
| no network / captive portal | gate waits up to 120s, then skips. Retries next hour. |
| power state unreadable (odd hardware, WSL with no session) | proceeds anyway rather than wedging forever. |
| outside the quiet window | skipped — **unless** nothing has succeeded in 24h, then it runs anyway. |
| a run happened recently | skipped for 6h regardless of window or staleness, so a 7h-wide window and an hourly poll can't mean seven rebuilds a night. |
| `~/nixos` clone missing or previously failed | retried hourly by its own ungated timer, never once-per-boot. |
| auto-update itself broken/gated | the clone timer is independent of it, so the hand-deploy checkout still lands. |
| `~/nixos` exists, non-empty, not a repo | refuses with an explicit "move it aside" message and does not fail the run. |
| one user's HM activation fails | loop continues to the remaining users; the unit exits **non-zero** so it shows red. |
| any step failed | `last-success` is **not** advanced, so the 24h staleness fallback keeps retrying — throttled to once every 6h, not once an hour, so a permanently-broken step can't become a rebuild loop. |
| kernel/initrd changed | new generation is built and switched, but **no reboot** — the journal notes that one is needed. |
| `nixos-rebuild` restarts units mid-switch | all three units carry `X-RestartIfChanged=false`, `X-StopIfChanged=false`, `X-StopOnRemoval=false` so the switch can't tear down the process performing it. |
| flake inputs moved upstream | irrelevant — hosts deploy the `flake.lock` committed in the repo. Lock bumps are a reviewed PR, never a per-host decision. |

---

## Driving it by hand

```sh
# What's the state of play on this host?
auto-update-status

# Do it now, ignoring window / AC / staleness / reachability.
sudo auto-update-now

# Watch it.
journalctl -fu auto-update.service \
           -u nixos-auto-upgrade.service \
           -u hm-auto-upgrade.service

# Run just one half (also bypasses the gate).
sudo systemctl start nixos-auto-upgrade.service
sudo systemctl start hm-auto-upgrade.service

# Quiet, for a long refactor. (Undo with `start`.)
sudo systemctl stop auto-update.timer
```

`auto-update-status` prints the flake URI, the step order, the window and
staleness policy, whether AC is required, when the last run and last
*successful* run were, the per-step result of that last run, the timer's
next fire, and the current unit states.

---

## Tuning it per host

All knobs are NixOS options under `autoUpdate.*`, set from a host bridge:

```nix
autoUpdate = {
  interval           = "1h";                              # poll cadence
  quietWindow        = { start = "02:00"; end = "09:00"; };  # null = any time
  staleAfterHours    = 24;
  minIntervalHours   = 6;                                 # rate limit between attempts
  requireAC          = true;                              # false on a desktop-ish host
  networkWaitSeconds = 120;
  triggerOnAC        = true;                              # udev poke on plug-in
  flake              = "github:dc0d32/nixos";
};
```

`quietWindow` supports windows that wrap midnight (`start > end`).

---

## Why the previous design failed

Worth recording, because the failure modes were invisible rather than
loud:

1. **Two independent calendar timers** — `nixos-upgrade.timer` at 04:40
   and `hm-auto-upgrade.timer` at 05:30. Laptops are suspended or off at
   04:40. `Persistent=true` grants exactly **one** make-up run, fired the
   instant the lid opens — the worst possible moment, because WiFi hasn't
   associated yet and the machine is on battery. It fails, and the next
   opportunity is 24 hours later. Hosts drifted for weeks.
2. **No ordering.** On a catch-up boot both timers elapsed at once, so
   `home-manager switch` raced `nixos-rebuild switch`.
3. **`exit 0` regardless.** The HM step always exited zero "so a
   transient failure on user A doesn't obscure real failures". The effect
   was the opposite: a user whose activation had been failing every night
   for weeks looked identical to a clean run in `systemctl status`.
4. **No power policy.** A full closure download plus activation on
   battery, on a laptop the user has just opened.

See `docs/sessions/2026-08-04-opportunistic-auto-update.md` for the
session that replaced it.
