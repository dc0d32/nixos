#!/usr/bin/env python3
"""timekpr-sync — report local screen-time usage, apply the shared remainder.

Deployed by flake-modules/timekpr-sync.nix; see that file for why this
exists and its retirement condition. Reads a JSON spec (argv[1]) written
into the nix store by the module.

Replaces a shell agent that silently did nothing for its whole life: it
read `<workdir>/timekpr.<user>.time`, but upstream names the file
`<workdir>/<user>.time` (timekpr common/utils/config.py:
`os.path.join(pDirectory, "%s.time" % (pUserName))`), and the guard around
the missing file swallowed it.

Why reporting TIME_SPENT_DAY and writing back via `timekpra` does not form
a feedback loop: `--settimeleft <user> = <n>` is implemented (timekpr
server/config/configprocessor.py::checkAndSetTimeLeft) as
`TIME_SPENT_BALANCE = limit_today - n`. It never touches TIME_SPENT_DAY.
So TIME_SPENT_DAY stays a pristine local measurement of seconds actually
consumed on THIS host, which is exactly what the controller needs to sum,
while TIME_SPENT_BALANCE is the writable knob enforcement reads.
"""

import configparser
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

# timekpr writes LIMITS_PER_WEEKDAYS in ISO weekday order (Monday first),
# which lines up with datetime.weekday() == 0 for Monday.
TIMEKPR_DATETIME_FORMAT = "%Y-%m-%d %H:%M:%S"


def log(message):
    print(f"timekpr-sync: {message}", file=sys.stderr)


def read_ini(path):
    parser = configparser.ConfigParser()
    # timekpr's own files are plain INI, but be liberal: a stray comment
    # style or duplicate key should degrade to "skip this user", not crash
    # the whole run and leave the other kid unsynced.
    try:
        with open(path, "r", encoding="utf-8") as fh:
            parser.read_file(fh)
    except (OSError, configparser.Error) as exc:
        log(f"cannot parse {path}: {exc}")
        return None
    return parser


def local_state(work_file, username, now):
    """(spent_today, balance) from the daemon's work file, or None.

    Returns None when the file is missing or stale. Staleness matters: the
    daemon rewrites LAST_CHECKED continuously, so a file whose date is not
    today is left over from a previous day and its TIME_SPENT_DAY belongs
    to that day. Reporting it would bill the kid twice for yesterday.
    """
    parser = read_ini(work_file)
    if parser is None or not parser.has_section(username):
        return None
    section = parser[username]

    last_checked = section.get("LAST_CHECKED", "").strip()
    try:
        checked_at = datetime.strptime(last_checked, TIMEKPR_DATETIME_FORMAT)
    except ValueError:
        log(f"{username}: unparsable LAST_CHECKED {last_checked!r}, skipping")
        return None
    if checked_at.date() != now.date():
        log(f"{username}: work file is from {checked_at.date()}, not today; skipping")
        return None

    try:
        spent = int(section.get("TIME_SPENT_DAY", "").strip())
        balance = int(section.get("TIME_SPENT_BALANCE", "").strip())
    except ValueError:
        log(f"{username}: missing/non-numeric TIME_SPENT_DAY or _BALANCE, skipping")
        return None
    return spent, balance


def local_limit_today(config_file, username, now):
    """Today's local cap in seconds from LIMITS_PER_WEEKDAYS, or None."""
    parser = read_ini(config_file)
    if parser is None or not parser.has_section(username):
        return None
    raw = parser[username].get("LIMITS_PER_WEEKDAYS", "")
    parts = [p.strip() for p in raw.split(";") if p.strip()]
    if len(parts) != 7:
        log(f"{username}: LIMITS_PER_WEEKDAYS has {len(parts)} entries, expected 7")
        return None
    try:
        return int(parts[now.weekday()])
    except ValueError:
        log(f"{username}: non-numeric LIMITS_PER_WEEKDAYS entry")
        return None


def report(spec, host, username, spent):
    """POST usage upward; return (remaining_seconds, locked), or None.

    Any failure (server down, laptop off the LAN, DNS gone) returns None
    and the caller leaves local enforcement completely alone. Degrading to
    the per-host cap is the correct failure mode: never lock a kid out
    because a server is unreachable, and never hand out unlimited time.
    """
    body = urllib.parse.urlencode(
        {"host": host, "user": username, "spent": spent}
    ).encode("ascii")
    request = urllib.request.Request(
        spec["serverUrl"].rstrip("/") + "/report",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    token = spec.get("token")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=spec.get("timeout", 8)) as resp:
            payload = json.load(resp)
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError) as exc:
        log(f"{username}: report failed ({exc}); leaving local enforcement alone")
        return None
    remaining = payload.get("remaining")
    if not isinstance(remaining, int) or remaining < 0:
        log(f"{username}: server sent bad remaining {remaining!r}")
        return None
    # Absent on an older controller; treat only an explicit true as a lock so
    # a missing field can never strand a kid.
    return remaining, payload.get("locked") is True


def lock_sessions(loginctl, username):
    """Lock the user's graphical sessions right now.

    Zeroing the budget makes timekpr enforce its configured LOCKOUT_TYPE,
    but only on its own tick and only for as long as the kid is inside a
    tracked session. `loginctl lock-session` closes the gap so a parent
    pressing Lock sees the screen go within a poll interval instead of
    whenever the daemon next looks. Best effort: no sessions, or a session
    whose compositor doesn't implement the lock signal, is not an error we
    can do anything about, and the zeroed budget is the real enforcement.
    """
    listing = subprocess.run(
        [loginctl, "list-sessions", "--no-legend"],
        capture_output=True, text=True, check=False,
    )
    if listing.returncode != 0:
        return
    locked = 0
    for line in listing.stdout.splitlines():
        fields = line.split()
        # "<id> <uid> <user> <seat> <tty>" — user is the third column.
        if len(fields) >= 3 and fields[2] == username:
            result = subprocess.run(
                [loginctl, "lock-session", fields[0]],
                capture_output=True, text=True, check=False,
            )
            if result.returncode == 0:
                locked += 1
    if locked:
        log(f"{username}: locked {locked} session(s)")


def apply_remaining(timekpra, username, target):
    # "=" sets the remainder absolutely; "+"/"-" would be relative. Root is
    # allowed the admin D-Bus interface by upstream's policy (the timekpr
    # group), so no polkit prompt is involved.
    result = subprocess.run(
        [timekpra, "--settimeleft", username, "=", str(target)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        log(f"{username}: timekpra failed rc={result.returncode}: "
            f"{result.stderr.strip() or result.stdout.strip()}")
        return False
    return True


def sync_user(spec, host, username, now):
    state = local_state(f"{spec['workDir']}/{username}.time", username, now)
    if state is None:
        return
    spent, balance = state

    limit_today = local_limit_today(
        f"{spec['configDir']}/timekpr.{username}.conf", username, now
    )
    if limit_today is None:
        return

    answer = report(spec, host, username, spent)
    if answer is None:
        return
    remaining, locked = answer

    # Clamp what we are willing to apply. A spoofed controller on a hostile
    # network (or a fat-fingered grant) must not be able to hand out an
    # unbounded day; the local policy stays the ceiling, plus whatever
    # discretionary headroom the host allows.
    #
    # A lock bypasses the clamp in the ONLY safe direction: straight to 0.
    # The clamp exists to stop a hostile server granting time, so it has no
    # business standing between a parent and "off, now".
    ceiling = limit_today + spec["maxExtraMinutes"] * 60
    target = 0 if locked else max(0, min(remaining, ceiling))

    # What enforcement currently believes is left, by the same arithmetic
    # the daemon uses (server/user/userdata.py, TK_CTRL_SPENTBD).
    current = limit_today - balance

    # Only write when it actually matters. Every write touches the control
    # file, the daemon notices the mtime change, reloads, and fires
    # timeLeftChangedNotification — i.e. a tray popup for the kid. The old
    # agent did this unconditionally every 60s.
    #
    # A lock skips the tolerance gate: "close enough to zero" is not locked,
    # and re-asserting it every poll is what makes the lock stick if the kid
    # logs back in.
    if not locked and abs(target - current) <= spec["toleranceSeconds"]:
        return

    if apply_remaining(spec["timekpra"], username, target):
        log(f"{username}: local {current}s -> shared {target}s "
            f"(spent {spent}s here, cap {limit_today}s)"
            + (" [LOCKED]" if locked else ""))
    if locked:
        lock_sessions(spec["loginctl"], username)


def main():
    if len(sys.argv) != 2:
        print("usage: timekpr-sync <spec.json>", file=sys.stderr)
        return 2
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        spec = json.load(fh)

    if spec.get("tokenFile"):
        try:
            with open(spec["tokenFile"], "r", encoding="utf-8") as fh:
                spec["token"] = fh.read().strip()
        except OSError as exc:
            log(f"cannot read token file {spec['tokenFile']}: {exc}")

    now = datetime.now()
    host = spec["hostName"]
    for username in spec["users"]:
        sync_user(spec, host, username, now)
    return 0


if __name__ == "__main__":
    sys.exit(main())
