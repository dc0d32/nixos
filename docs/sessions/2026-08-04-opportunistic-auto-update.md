# 2026-08-04 — opportunistic auto-update

Replaced the two-calendar-timer auto-deploy with a polling driver that
gates on time-of-day, staleness, wall power and reachability, and that
sequences the system rebuild before every user's home-manager
activation. Extended auto-deploy to `pb-x1` (the dev box) now that the
gate makes it non-disruptive.

User-facing summary lives in [`docs/auto-update.md`](../auto-update.md);
this file records why the decisions were made.

## The complaint

> Currently there's a night time timer, but looks like things are not
> working. Those machines either are asleep at the time, or not all
> users update. I don't know what's happening.

Both halves of that turned out to be real, and a third problem
(invisibility) was what made them survive so long.

## What was actually wrong

**1. A calendar timer on machines that are asleep at that hour.**
`system.autoUpgrade.dates = "04:40"` plus `hm-auto-upgrade.timer` at
05:30. `Persistent=true` does catch "the host was powered down", but it
grants exactly **one** make-up run, fired the instant the timer's
elapse is noticed — i.e. the moment the lid opens. That is the worst
possible moment: WiFi hasn't associated, the machine is on battery, and
the user is trying to use it. The run fails, and because both units are
once-daily `OnCalendar` timers with no retry, the next opportunity is 24
hours later. Multiply by "the laptop is only opened on weekends" and
hosts drift for weeks.

**2. No ordering between the two timers.** 04:40 + 30min jitter vs 05:30
+ 30min jitter only holds while both runs are punctual. On a catch-up
boot both elapsed timers fire at the same instant, so `home-manager
switch` raced `nixos-rebuild switch` — HM activating against the
outgoing system closure, two `nix build`s competing for the same
substituter bandwidth.

**3. Per-user failures were structurally invisible.** The HM loop ended
with `exit 0` unconditionally, justified in the module header as "a
transient WiFi flake on user A shouldn't block the timer's succeeded-last-run
status and obscure real failures". The effect was the exact opposite: a
user whose activation had been failing every single night for weeks was
indistinguishable, in `systemctl status`, from a clean run. There was no
stamp file, no status command, nothing to look at except raw journal
archaeology on a machine you'd have to walk over to.

Enumeration was *not* the bug, incidentally — that was the first
hypothesis and it was wrong. Evaluating the generated script for
`pb-t480` showed all three users (`m`, `p`, `s`) present and correct. The
failure was at activation time, not module-eval time.

**4. Two latent activation bugs found by reading HM's `activate`.**
home-manager's generated activation script ends with

```sh
checkStringEq USER "$USER" p
checkPathEq   HOME "$HOME" /home/p
```

and hard-exits 1 on mismatch. The old invocation set `HOME` but relied
on `runuser` to set `USER` — which it does (util-linux `su-common.c`
`modify_environment()` sets USER/LOGNAME whenever `change_environment`
is on, and it is by default), so this happened to work. It is not
something to leave to a flag-dependent behaviour of `runuser` when the
consequence is a kid's laptop silently never updating, so both are now
set explicitly. `HOME` now comes from `users.users.<user>.home` instead
of a hardcoded `/home/<user>`.

The second one was live: activation ran with no `XDG_RUNTIME_DIR` and no
`DBUS_SESSION_BUS_ADDRESS`, so every `systemctl --user` call inside HM
activation failed to reach the user's systemd manager. For a
*logged-in* user that means the profile updates and the generation
advances — "success" — while waybar, mako and cliphist keep running the
old config until logout. Activation that succeeds and visibly changes
nothing is the most confusing possible failure mode, and matches "not
all users update" as reported. Both variables are now passed when
`/run/user/<uid>` exists; when it doesn't, the journal says so
explicitly and the new units start at next login.

**5. No power policy at all**, despite `backup.nix` having had one since
it was written.

## Decisions

### Poll, don't schedule

`OnBootSec=10min` + `OnUnitActiveSec=1h`, monotonic. systemd's monotonic
timers run off `CLOCK_BOOTTIME`, so suspend counts against them and a
machine waking after a long sleep fires promptly instead of waiting for a
calendar slot it already missed. Most polls cost nothing because the gate
exits in milliseconds.

Explicitly rejected: `WakeSystem=true`. A laptop in a bag stays asleep.

### `ExecCondition=`, not `ExecStartPre=`

This is the load-bearing systemd detail. A failed `ExecCondition` leaves
the unit **inactive**; a failed `ExecStartPre` leaves it **failed**. With
hourly polling and a gate that says "not now" most of the time,
`ExecStartPre` would mean the updater sits permanently in `failed` state
as a matter of normal operation — which destroys the one signal we
actually want (`failed` == something is genuinely broken). `backup.nix`'s
AC gate has this shape and gets away with it only because it fires once a
day.

Corollary: don't *wait* for conditions, *skip* on them. The old backup
pattern (block up to 4h waiting for AC) ties a unit up for hours; with an
hourly poll the retry loop is the timer, which is simpler and observable.

### Quiet window + staleness fallback

Asked the user whether updates should be allowed at any hour or should
prefer a quiet window; they chose the window with a fallback. Default
02:00–09:00 local, fall back to "any time" once the last **successful**
run is >24h old.

The morning edge at 09:00 is the important part and is not arbitrary: a
laptop suspended overnight is opened somewhere between 07:00 and 09:00,
and that wake *is* the realistic opportunity to update it. A window that
closed at 06:00 would be a window that never opens.

The staleness fallback is what makes the window safe. Without it, a
machine only ever used 09:00–23:00 never updates at all — the same class
of bug as the original design, just with a wider net.

Keyed on last **success**, not last run, so a failed step keeps the
fallback armed instead of resetting the clock. Stamp lives in
`/var/lib/auto-update/last-success`, added to the impermanence
persistence list (without that, every boot looks like "never updated" and
fires an unwanted rebuild the moment the machine comes up).

### The rate limit is not optional (caught in review)

The first cut of the gate had *only* the window and the staleness
fallback. Code review caught that this has no rate limit at all, in two
directions:

- The window is 7h wide and the timer polls hourly, so any host awake
  overnight (ah-1, m-pc, the WSL distros) would run the complete sequence
  ~7 times a night — and `--refresh` explicitly defeats nix's tarball
  cache, so each one re-fetches from GitHub, re-evaluates, and runs a
  full `switch-to-configuration switch`. On pb-x1 that would also be
  seven `home-manager switch`es from `github:` over local iteration per
  night, not the "one a night" the design intended.
- Worse: keying the fallback on last-*success* means a persistently
  failing step (a user whose HM activation collides with a stale dotfile
  — the scenario `hm-auto-upgrade.nix` explicitly names) never advances
  `last-success`, so `age` is permanently ≥24h and the fallback branch
  passes on *every* poll. Unbounded hourly full rebuild, forever, with
  no backoff.

Fixed with `minIntervalHours` (default 6), checked first, before the
window and before the expensive AC/network probes.

Two details of the implementation matter:

- It is keyed on **attempts**, not successes — otherwise it degenerates
  into the same unbounded retry loop it exists to prevent.
- The stamp is written by the **gate**, at the moment it decides to
  proceed, not by the sequencer when it finishes. A run killed by
  `TimeoutStartSec` or by a shutdown mid-switch never reaches the
  sequencer's epilogue, so stamping at the end would let a host that can
  never *complete* a run retry at the poll interval indefinitely.

Side benefit: it also caps the udev AC-plug trigger, so unplug/replug
cycling can't turn into a rebuild storm.

### One sequencer, `systemctl start --wait`

Considered three ways to order the system rebuild before HM:

- *Two timers, staggered* — what we had; breaks on catch-up.
- *`After=` between two timer-started units* — systemd ordering does
  apply to concurrently-queued jobs, but it's implicit and easy to
  break.
- *One oneshot that runs each step with `systemctl start --wait`* —
  chosen. Order is explicit, the sequencer sees each step's exit status
  and can aggregate it, and both steps remain independently startable by
  hand for debugging.

The step list is contributed by the feature modules via
`autoUpdate.steps` with explicit `lib.mkOrder` (100 system, 200 HM)
rather than relying on module import order.

**Rejected**: discovering steps by testing `config.systemd.services ?
nixos-auto-upgrade` inside the `mkIf` that *defines*
`systemd.services.auto-update`. That is an infinite recursion — computing
the attribute-name set requires evaluating the very condition being
computed. Tried it, got the error, switched to an option.

### Own the unit instead of bending `system.autoUpgrade`

Upstream's option is welded to a calendar timer (`startAt = cfg.dates`).
Reusing it meant `mkForce`-ing away its `OnCalendar` and its
`wantedBy = timers.target`, then bolting conditions onto a unit we don't
own — for the sake of borrowing one `nixos-rebuild switch` line.
`system.autoUpgrade.enable = false` is now set *explicitly* (not merely
omitted) so nobody helpfully turns it back on and ends up with two
competing rebuild units.

Kept from upstream: no reboots, no lock bumping. Both rationales are
unchanged and restated in `flake-modules/auto-upgrade.nix`.

Also carried over from upstream and easy to miss: `restartIfChanged =
false` / `stopIfChanged = false` / `X-StopOnRemoval = false` on every
unit in the chain. `nixos-rebuild switch` daemon-reloads and restarts
changed units mid-flight, and without these the switch can tear down the
very process performing it.

### Power detection, and what WSL needs

Factored the AC probe out of `backup.nix` into
`flake-modules/power-gate.nix` (`flake.lib.mkAcCheck`), shared by both.
Two real improvements fell out:

*Peripheral batteries.* Also caught in review, and nastier than it
looks: the classifier counted any `type=Battery` node as "this machine
has a battery". Bluetooth mice, keyboards, headsets, gamepads and Wacom
pens all publish exactly that, with `scope=Device`. On a desktop, pairing
a headset would flip the machine out of the "line power, no battery →
AC" fast path into the battery branch, where an idle USB-C port reading
`online=0` yields a verdict of BATTERY — a desktop that silently stops
updating *and* stops backing up, intermittently, depending on what is
connected. Now `scope=Device` nodes are skipped.

The same review found a hole in the branch table: `have_battery=1,
have_line=0` fell through to the "no battery and no line node → desktop"
branch and reported AC, i.e. a laptop whose mains node is missing or
unreadable would be treated as plugged in. That case is now an explicit
UNKNOWN.

Both were verified against a synthetic sysfs tree covering desktop+mouse
(AC online and offline), laptop+mouse on battery and on AC, and
battery-with-no-line-node.

*Node discovery.* The old copy checked four hardcoded names
(`AC`/`ACAD`/`AC0`/`ADP1`) and, finding none, logged "assuming desktop,
proceeding". On any laptop whose mains supply is named something else
that reads as "always run the backup". The new probe scans every
`/sys/class/power_supply/*` and classifies by `type`, counting `Mains`
**and** `USB*` as line power — a USB-C-only laptop has no `AC` node,
only `ucsi-source-psy-USBC000:00N` with `type=USB`. (On `pb-x1` both are
present and both track the charger, which is how the classifier got
validated: mid-session the charger was unplugged and the probe correctly
flipped to `BATTERY` without being asked to.)

*WSL.* The user asked for WSL to hold off on battery too. WSL2's kernel
exposes no `power_supply` class at all — there is no virtual battery — so
sysfs can't answer. Confirmed there's no plan upstream to add one. The
probe therefore asks Windows over interop for
`SystemInformation.PowerStatus.PowerLineStatus` (`Online`/`Offline`/
`Unknown`), which needs no elevation, unlike `root\wmi`'s `BatteryStatus`
class.

The non-obvious part: a systemd **system** service inherits no
`WSL_INTEROP`, and the binfmt handler refuses to launch a `.exe` without
one. The probe recovers the most recently created per-session socket from
`/run/WSL/*_interop` and exports it before exec'ing `powershell.exe`. If
there is no session at all there is nothing to inherit — and a WSL distro
with no open session isn't costing anyone battery — so that case returns
"undeterminable" and the update proceeds.

Three-valued result (`0` AC / `1` battery / `2` undeterminable) rather
than a boolean, because both callers want to treat "can't tell" as
"proceed". A machine whose power state can't be read but that therefore
never updates or backs up is worse than one that occasionally does so on
battery.

### The CA bug that would have silently broken everything

The reachability probe initially failed on every invocation with
`unable to get local issuer certificate`. Cause: a systemd service
inherits none of the session variables NixOS sets for interactive shells,
so curl has no CA bundle. This is exactly the class of bug that would
have shipped as "the updater mysteriously never runs" — the gate would
have skipped every single poll, quietly and correctly-looking, forever.
Found only because the generated gate script was run by hand in a
scrubbed environment (`env -i PATH=/run/current-system/sw/bin …`), which
is now the recommended way to test any unit script in this repo. Fixed by
passing `SSL_CERT_FILE`/`NIX_SSL_CERT_FILE` explicitly, with a plain TCP
connect as a fallback so a CA problem can never be the thing that wedges
the updater.

### Fail loudly

`hm-auto-upgrade` still continues past a failing user — one stale
colliding dotfile must not stop the other two — but now exits non-zero if
any user failed. Combined with not advancing `last-success`, a persistent
per-user failure now both shows red in `systemctl status` and keeps the
staleness fallback retrying, instead of looking identical to a clean run.

Added `auto-update-status` (policy, last run, last success, per-step
result, next fire, unit states) and `auto-update-now` (force a run,
bypassing every gate) because "I don't know what's happening" was half
the original complaint and no amount of correct scheduling fixes that on
its own.

### pb-x1 joins auto-deploy

The dev box was excluded because "a 04:40 nixos-rebuild timer racing
in-progress edits and a 05:30 `home-manager switch` from github: that
blows away local HM iteration are more annoying than useful". The user
asked for it to be included. The gate defuses most of that: it only fires
inside 02:00–09:00 unless the host has gone >24h without a successful
run, and it holds off on battery. It does still activate whatever is
pushed over the top of local iteration — the accepted trade — and
`systemctl stop auto-update.timer` buys quiet for a long refactor.

## Verification

- All six NixOS hosts smoke-build (`pb-x1`, `pb-t480`, `m-pc`, `ah-1`,
  `wsl`, `wsl-arm`); `nix flake check --impure` passes, including the
  pre-commit hooks.
- `ac-check` validated live on `pb-x1` in both states — reported AC with
  the charger in, and correctly flipped to `BATTERY` when it came out
  mid-session.
- The full gate was run in a scrubbed environment
  (`env -i PATH=/run/current-system/sw/bin …`) and passes all four
  checks; the window, staleness, battery-skip and unreachable-skip
  branches were each exercised.
- The exact `runuser` environment the HM step constructs was replayed
  against a real `activationPackage` with `DRY_RUN=1` and a scrubbed
  env — HM's `USER`/`HOME` sanity checks pass and the `systemctl --user`
  calls resolve.
- Generated `hm-auto-upgrade-run` for `pb-t480` enumerates `m`, `p` and
  `s` with the correct home directories.
- `ac-check` classification verified against a synthetic
  `/sys/class/power_supply` tree: desktop + paired bluetooth mouse (AC
  online → AC; AC offline → still AC, because the mouse is `scope=Device`
  and doesn't count), laptop + mouse on battery → BATTERY, laptop + mouse
  on AC → AC, system battery with no line node → UNKNOWN.
- Gate throttle verified end to end: first call proceeds and writes
  `last-attempt`, an immediate second call is skipped, `AUTO_UPDATE_FORCE`
  bypasses it, a 7h-old attempt with no recorded success takes the
  staleness path, and a 7h-old attempt with a 1h-old success outside the
  window is skipped.
- Code review by a second agent; both issues it raised (the missing rate
  limit and the peripheral-battery misclassification) are fixed above.
  It independently confirmed there is no ordering relationship between
  `auto-update.service` and the units it starts, so `systemctl start
  --wait` cannot deadlock; that `switch-to-configuration-ng` honours the
  three `X-*` unit flags; that `switch-to-configuration` issues no
  `udevadm trigger`, so the AC udev rule can't re-fire mid-switch; and
  that `mkOrder` merges correctly through the `mkIf` on all six hosts.

## Follow-up

Backup is next: `backup.nix` still has a daily 03:00 calendar timer with
a 4h blocking AC wait, i.e. the design this session just replaced for
updates. It now at least shares the corrected power probe. Revisiting it
was explicitly deferred to a follow-up session.
