# timekpr: make the curfew visible (dashboard calendar)

Follow-on to `2026-07-28-timekpr-central.md`, same day, after the
controller went live on ursa.

## The report

> "s says they have about 5 hours today, but when I log in as s on t480,
> timekpr instantly locks me out"

## Diagnosis: not a bug — two independent axes

`s` genuinely had `14400 (budget) + 3600 (grant) - 23 (spent) = 17977s`,
which is the "about 5 hours" the dashboard showed. It was 23:35 on a
Tuesday, and Tuesday's window is `06:00-22:00`. The window had been shut
for 95 minutes.

Budget and allowed-hours are **independent axes** in timekpr, and the
budget is only ever an *upper bound* on what an allowed hour can yield.
From `timekpr-0.5.8/.../server/user/userdata.py`:

```python
# l.199
secondsToAddHour = max(min(secondsLeftHour, secondsLeftHourLimit, secondsLeft), 0)
# l.214 — accumulates only for ACTIVE hours contiguous from now
self._timekprUserData[cons.TK_CTRL_LEFT] += secondsToAddHour if contTime else 0
```

`secondsLeft` (budget + bonus) enters only through `min(...)`. So:

- **Granting time can never open a blocked hour.** The parent's +1h that
  evening was unspendable the moment it was granted, and — because grants
  are keyed `(day, username)` (`Store.add_bonus`) — it expired at midnight
  unused.
- Conversely, an open hour with no budget yields nothing either.

So the system was correct and the *dashboard* was the defect: it reported
one axis as if it were the whole truth. "4h 59m left" was simultaneously
accurate and unusable, and there was no way to tell which from the UI.

## Fix: show both axes

`allowedHoursByDay` is now plumbed into the controller and rendered as a
7-day × 24-hour grid per user, with today's row emphasised, the current
hour outlined, and each day's budget in the right-hand column. Outside the
window the big number is annotated:

> 🌙 curfew — today's window 06:00-22:00 is shut, opens Wed 06:00

and inside it:

> window 06:00-23:00 · shuts Sat 23:00

### Deliberately display-only

The controller does **not** fold the window into `remaining`, for two
reasons:

1. It cannot enforce it anyway. The local timekpr daemon is the only thing
   watching the session, and it already enforces hours correctly.
2. Zeroing `remaining` during a curfew would make a curfew look identical
   to an exhausted budget, and would make a parent's grant appear to do
   nothing — the exact confusion this change exists to remove.

`remaining` therefore stays a pure budget pool, and the window keys
(`withinWindow`, `windowToday`, `changesAt`, `changesAtLabel`) are
*additive* to the JSON. Agents are unaffected.

### Single-sourcing

`homelab/nix/hosts/ursa.nix` feeds
`pub.lib.kidTimekprPolicy.allowedHoursByDay` — the same attrset the kid
hosts render into their local timekpr config. Retyping it would let the
dashboard drift from what is actually enforced, which would be strictly
worse than showing nothing. All seven days are required (build-time error
on a missing day), matching `budgetMinutesByDay`.

The controller parses the window with the same semantics the Nix renderer
uses: hour grain, start inclusive, **end exclusive** — `06:00-22:00`
permits `06:00..21:59`.

## Degradation

A spec with no `allowedHoursByDay` (an older deployment) renders no
calendar, no banner, and emits no window keys, rather than erroring. A
malformed window string yields `None` from `parse_window`, so that day
shows as fully blocked instead of taking the page down — the Nix side
already rejects the same strings at build time via `strMatching`, so this
is belt-and-braces.

## Verified

- Curfew case (Tue 23:35, window 06:00-22:00) → `withinWindow: false`,
  opens `Wed 06:00`.
- In-window case (Sat 14:20) → `withinWindow: true`, shuts `Sat 23:00`.
- Pre-open case (Tue 03:00) → opens `Tue 06:00` (same day, not tomorrow).
- Friday 23:30 → next opening correctly reads **Saturday's** start hour,
  not Friday's, since weekend windows differ.
- Grid cell counts: 114 allowed / 54 blocked = 5×16 + 2×17 out of 168.
- Rendered HTML is tag-balanced; screenshotted both the curfew and the
  in-window/locked states.
- Spec JSON on ursa carries both axes for `m` and `s`, identical to
  `kidTimekprPolicy`.
- `nixpkgs-fmt` clean, `nix flake check --impure` passes, ursa toplevel
  builds (6 derivations: spec JSON, unit, and downstream only).

## Gotcha recorded

`nixpkgs-fmt` must **not** be run across the `homelab/` submodule — it is
not nixpkgs-fmt-formatted and 17 unrelated files get rewritten. Scope it:
`git ls-files '*.nix' | grep -v '^homelab/' | xargs nixpkgs-fmt`.
