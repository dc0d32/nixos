#!/usr/bin/env python3
"""timekpr-central — cross-host shared screen-time budget controller.

Deployed by flake-modules/timekpr-central.nix; see that file for why this
exists and its retirement condition. Reads a JSON spec (argv[1]) written
into the nix store by the module.

Deliberately stdlib-only (http.server + sqlite3): the closure stays tiny
and there is no web framework to keep patched on a box whose whole job is
to answer a handful of requests a minute from three laptops.

Data model
----------
usage(day, username, host) -> spent seconds, updated MONOTONICALLY:
each report does `spent = max(spent, reported)`. That is the anti-tamper
property. A kid who forges a LOW report cannot rewind the counter, and a
forged HIGH report only costs them their own time. It also makes the
agent's at-least-once retry loop idempotent, and survives a host whose
work file is deleted mid-day (the counter simply stops advancing for that
host instead of dropping).

grants(day, username) -> bonus seconds, may be negative (parent takes
time away). Grants are per-day so they evaporate at midnight rather than
silently inflating tomorrow.

remaining = budget(today) + bonus - sum(spent over all hosts), clamped
at >= 0.

allowedHoursByDay (optional per user) is the same "HH:MM-HH:MM" window
the kid hosts render into their local timekpr config, carried here for
DISPLAY ONLY. It is never folded into `remaining`: in timekpr the budget
and the window are independent axes (server/user/userdata.py takes
min(secondsLeft, per-hour limits)), so a grant cannot open a blocked
hour, and collapsing them here would make a curfew indistinguishable
from an exhausted budget — which would make a parent's grant appear to
do nothing. Absent from the spec, the calendar and curfew banner are
simply not rendered and the JSON gains no window keys.
"""

import base64
import hmac
import html
import json
import os
import sqlite3
import sys
import urllib.parse
from datetime import datetime, timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Monday=0 .. Sunday=6, matching datetime.weekday(), so the spec's
# by-weekday budget map can be indexed straight from the local date.
DAY_NAMES = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

# These requests carry a handful of short form fields. Anything bigger is a
# mistake or an attempt to make the server allocate on demand.
MAX_BODY_BYTES = 64 * 1024

SCHEMA = """
CREATE TABLE IF NOT EXISTS usage (
    day        TEXT    NOT NULL,
    username   TEXT    NOT NULL,
    host       TEXT    NOT NULL,
    spent      INTEGER NOT NULL,
    updated_at TEXT    NOT NULL,
    PRIMARY KEY (day, username, host)
);
CREATE TABLE IF NOT EXISTS grants (
    day        TEXT    NOT NULL,
    username   TEXT    NOT NULL,
    bonus      INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT    NOT NULL,
    PRIMARY KEY (day, username)
);
-- Parent-initiated lock. Not per-day and not per-host: a lock means "off
-- every machine, now, until I say otherwise", so it deliberately survives
-- midnight and a controller restart. `until` NULL = indefinite.
CREATE TABLE IF NOT EXISTS locks (
    username   TEXT PRIMARY KEY,
    until      TEXT,
    updated_at TEXT NOT NULL
);
"""


def read_secret(path):
    """Read a secret file, returning None if it is absent or empty.

    Absent is not fatal: the module documents these as operator-provisioned
    files under /persist, and a controller that refuses to start because the
    parent has not written a password yet is worse than one that starts and
    logs loudly (the kids' hosts would fall back to their local caps).
    """
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            value = fh.read().strip()
    except OSError as exc:
        print(f"timekpr-central: cannot read {path}: {exc}", file=sys.stderr)
        return None
    return value or None


class Store:
    def __init__(self, db_path):
        self.db_path = db_path
        with self._connect() as conn:
            conn.executescript(SCHEMA)

    def _connect(self):
        # One connection per operation. ThreadingHTTPServer serves each
        # request on its own thread and sqlite3 connections are not
        # shareable across threads; at this request rate the open cost is
        # irrelevant next to the correctness win.
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=10000")
        return conn

    def record(self, day, username, host, spent):
        now = datetime.now().isoformat(timespec="seconds")
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO usage (day, username, host, spent, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (day, username, host) DO UPDATE SET
                    spent      = MAX(usage.spent, excluded.spent),
                    updated_at = excluded.updated_at
                """,
                (day, username, host, spent, now),
            )

    def per_host(self, day, username):
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT host, spent, updated_at FROM usage "
                "WHERE day = ? AND username = ? ORDER BY host",
                (day, username),
            ).fetchall()
        return [{"host": r[0], "spent": r[1], "updated_at": r[2]} for r in rows]

    def bonus(self, day, username):
        with self._connect() as conn:
            row = conn.execute(
                "SELECT bonus FROM grants WHERE day = ? AND username = ?",
                (day, username),
            ).fetchone()
        return row[0] if row else 0

    def add_bonus(self, day, username, seconds):
        now = datetime.now().isoformat(timespec="seconds")
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO grants (day, username, bonus, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (day, username) DO UPDATE SET
                    bonus      = grants.bonus + excluded.bonus,
                    updated_at = excluded.updated_at
                """,
                (day, username, seconds, now),
            )

    def set_lock(self, username, until):
        """Lock `username`. `until` is a datetime, or None for indefinite."""
        now = datetime.now().isoformat(timespec="seconds")
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO locks (username, until, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT (username) DO UPDATE SET
                    until      = excluded.until,
                    updated_at = excluded.updated_at
                """,
                (username, until.isoformat(timespec="seconds") if until else None, now),
            )

    def clear_lock(self, username):
        with self._connect() as conn:
            conn.execute("DELETE FROM locks WHERE username = ?", (username,))

    def lock_state(self, username, when):
        """(locked, until_iso_or_None). Expired timed locks self-clear."""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT until FROM locks WHERE username = ?", (username,)
            ).fetchone()
        if row is None:
            return False, None
        until = row[0]
        if until is None:
            return True, None
        try:
            expires = datetime.fromisoformat(until)
        except ValueError:
            # Unparseable value would otherwise pin the kid forever.
            self.clear_lock(username)
            return False, None
        if when >= expires:
            self.clear_lock(username)
            return False, None
        return True, until


class Controller:
    def __init__(self, spec):
        self.users = spec["users"]
        self.store = Store(os.path.join(spec["stateDir"], "usage.db"))
        self.admin_user = spec.get("adminUser") or "parent"
        self.admin_password = read_secret(spec.get("adminPasswordFile"))
        self.token = read_secret(spec.get("tokenFile")) or (spec.get("token") or None)

    def budget_seconds(self, username, when):
        user = self.users.get(username)
        if user is None:
            return None
        return user["budgetMinutesByDay"][DAY_NAMES[when.weekday()]] * 60

    def window(self, username, weekday):
        """(start_hour, end_hour) for one weekday, or None if not configured.

        End is EXCLUSIVE, matching the module that renders these same strings
        into timekpr's hour-grain ALLOWED_HOURS_<n>: "06:00-22:00" permits
        06:00..21:59. Returns None rather than raising when the spec predates
        the option, so an old spec degrades to "no calendar" instead of a
        crashed dashboard.
        """
        user = self.users.get(username)
        if user is None:
            return None
        windows = user.get("allowedHoursByDay")
        if not windows:
            return None
        return parse_window(windows.get(DAY_NAMES[weekday]))

    def window_state(self, username, when):
        """Curfew picture for `when`: is the window open, and when does it flip?

        This is DISPLAY ONLY. The controller deliberately does not fold the
        window into `remaining` — budget and window are independent axes in
        timekpr (`server/user/userdata.py` takes min(secondsLeft, hour
        limits), so a grant can never open a blocked hour), and the local
        daemon is the only thing positioned to enforce either. Collapsing
        them here would make a curfew look like an exhausted budget and
        would mean a parent's grant appeared to do nothing.
        """
        win = self.window(username, when.weekday())
        if win is None:
            return None
        start, end = win
        within = start <= when.hour < end
        if within:
            flip = when.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(hours=end)
        elif when.hour < start:
            flip = when.replace(hour=start, minute=0, second=0, microsecond=0)
        else:
            # Past today's close: the next opening is tomorrow's start hour,
            # which may differ from today's (weekend windows are wider).
            nxt = self.window(username, (when.weekday() + 1) % 7)
            nxt_start = start if nxt is None else nxt[0]
            flip = (when + timedelta(days=1)).replace(
                hour=nxt_start, minute=0, second=0, microsecond=0
            )
        return {
            "withinWindow": within,
            "windowToday": fmt_window(start, end),
            "changesAt": flip.strftime("%Y-%m-%d %H:%M"),
            "changesAtLabel": flip.strftime("%a %H:%M"),
        }

    def status(self, username, when):
        """Full picture for one user on one day. None if user is unknown."""
        budget = self.budget_seconds(username, when)
        if budget is None:
            return None
        day = when.strftime("%Y-%m-%d")
        hosts = self.store.per_host(day, username)
        bonus = self.store.bonus(day, username)
        spent = sum(h["spent"] for h in hosts)
        locked, until = self.store.lock_state(username, when)
        st = {
            "user": username,
            "day": day,
            "budget": budget,
            "bonus": bonus,
            "spent": spent,
            # A locked user has no time, whatever the ledger says. Reported
            # here rather than only in `locked` so an agent that predates the
            # lock feature still does the right thing.
            "remaining": 0 if locked else max(0, budget + bonus - spent),
            "locked": locked,
            "lockedUntil": until,
            "hosts": hosts,
        }
        # Additive: absent when the spec carries no windows, and never folded
        # into `remaining`, so agents are unaffected either way.
        win = self.window_state(username, when)
        if win is not None:
            st.update(win)
        return st


def parse_window(window):
    """"HH:MM-HH:MM" -> (start_hour, end_hour), or None if unusable.

    Minutes are accepted and ignored, exactly as timekpr's hour-grain
    accounting ignores them. Anything malformed yields None so a typo
    degrades the calendar rather than taking the dashboard down; the Nix
    side already rejects the same strings at build time.
    """
    if not isinstance(window, str):
        return None
    try:
        start_s, end_s = window.split("-", 1)
        start = int(start_s.split(":", 1)[0])
        end = int(end_s.split(":", 1)[0])
    except (ValueError, AttributeError):
        return None
    if not (0 <= start <= 23 and 0 < end <= 24 and start < end):
        return None
    return start, end


def fmt_window(start, end):
    return f"{start:02d}:00-{end:02d}:00"


def fmt_hms(seconds):
    sign = "-" if seconds < 0 else ""
    seconds = abs(int(seconds))
    return f"{sign}{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


DAY_LABELS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def render_calendar(controller, username, now):
    """A week x 24h grid of the allowed window, with today and now marked.

    The point of this is to make the two independent axes visible at a
    glance. A parent looking at "4h 59m left" at 23:35 cannot tell from the
    number alone that the window shut at 22:00; the grid shows the shut
    window, the current hour sitting outside it, and the budget for each day
    in one place. Returns "" when the spec carries no windows.
    """
    user = controller.users.get(username) or {}
    if not user.get("allowedHoursByDay"):
        return ""

    head = "".join(
        f"<div class=hh>{h if h % 3 == 0 else ''}</div>" for h in range(24)
    )
    rows = []
    for idx, label in enumerate(DAY_LABELS):
        win = controller.window(username, idx)
        budget = user["budgetMinutesByDay"][DAY_NAMES[idx]]
        is_today = idx == now.weekday()
        cells = []
        for h in range(24):
            on = win is not None and win[0] <= h < win[1]
            klass = "on" if on else "off"
            if is_today and h == now.hour:
                klass += " now"
            cells.append(f"<div class='{klass}'></div>")
        dl = "dl today" if is_today else "dl"
        rows.append(
            f"<div class='{dl}'>{label}</div>"
            + "".join(cells)
            + f"<div class=bd>{budget // 60}h{budget % 60:02d}</div>"
        )
    return f"""
      <div class=calwrap>
        <div class=cal>
          <div></div>{head}<div></div>
          {"".join(rows)}
        </div>
      </div>
      <p class="dim legend">
        <span class="sw on"></span> allowed
        <span class="sw off"></span> curfew
        <span class="sw now"></span> now
        &middot; right column is that day's budget
      </p>"""


def render_dashboard(controller, now):
    rows = []
    for username in sorted(controller.users):
        st = controller.status(username, now)
        host_bits = "".join(
            f"<li><code>{html.escape(h['host'])}</code> "
            f"{fmt_hms(h['spent'])} "
            f"<span class=dim>(last report {html.escape(h['updated_at'])})</span></li>"
            for h in st["hosts"]
        ) or "<li class=dim>no reports today</li>"
        pct = min(100, int(100 * st["spent"] / max(1, st["budget"] + st["bonus"])))
        bonus_bit = (
            f" <span class=dim>({fmt_hms(st['bonus'])} granted)</span>"
            if st["bonus"]
            else ""
        )
        user_esc = html.escape(username)
        if st["locked"]:
            until_bit = (
                f" until {html.escape(st['lockedUntil'].replace('T', ' '))}"
                if st["lockedUntil"]
                else ""
            )
            state = f'<p class="big locked">&#128274; locked{until_bit}</p>'
            lock_form = f"""
              <form method=post action=/unlock>
                <input type=hidden name=user value="{user_esc}">
                <button class=ok>Unlock</button>
              </form>"""
        else:
            state = f"<p class=big>{fmt_hms(st['remaining'])} left</p>"
            # The whole reason the calendar exists: budget and window are
            # independent, so "X left" alone is a half-truth outside the
            # window. Say so on the same line the number appears on.
            if st.get("withinWindow") is False:
                state += (
                    f'<p class=curfew>&#127769; curfew &mdash; today\'s window '
                    f'{html.escape(st["windowToday"])} is shut, '
                    f'opens {html.escape(st["changesAtLabel"])}</p>'
                )
            elif st.get("withinWindow") is True:
                state += (
                    f'<p class=dim>window {html.escape(st["windowToday"])} '
                    f'&middot; shuts {html.escape(st["changesAtLabel"])}</p>'
                )
            lock_form = f"""
              <form method=post action=/lock>
                <input type=hidden name=user value="{user_esc}">
                <button name=minutes value=0 class=neg>Lock</button>
                <button name=minutes value=30 class=neg>Lock 30m</button>
                <button name=minutes value=120 class=neg>Lock 2h</button>
              </form>"""
        rows.append(
            f"""
            <section>
              <h2>{user_esc}</h2>
              {state}
              <p>used {fmt_hms(st['spent'])} of {fmt_hms(st['budget'])}{bonus_bit}</p>
              <div class=bar><div class=fill style="width:{pct}%"></div></div>
              {render_calendar(controller, username, now)}
              <ul>{host_bits}</ul>
              <form method=post action=/grant>
                <input type=hidden name=user value="{user_esc}">
                <button name=minutes value=15>+15m</button>
                <button name=minutes value=30>+30m</button>
                <button name=minutes value=60>+60m</button>
                <button name=minutes value=-30 class=neg>-30m</button>
              </form>
              {lock_form}
            </section>
            """
        )
    return f"""<!doctype html>
<html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>screen time</title>
<style>
 body {{ font-family: system-ui, sans-serif; margin: 0 auto; max-width: 40rem;
        padding: 1rem; background: #14161a; color: #e6e6e6; }}
 h1 {{ font-size: 1.1rem; font-weight: 500; color: #9aa4b2; }}
 section {{ background: #1d2027; border-radius: .6rem; padding: 1rem;
            margin-bottom: 1rem; }}
 h2 {{ margin: 0; font-size: 1.4rem; }}
 .big {{ font-size: 2rem; margin: .2rem 0; }}
 .dim {{ color: #7d8794; }}
 .bar {{ background: #2b303a; border-radius: .3rem; height: .5rem;
         overflow: hidden; margin: .6rem 0; }}
 .fill {{ background: #4c9aff; height: 100%; }}
 ul {{ list-style: none; padding: 0; font-size: .9rem; }}
 button {{ font-size: 1rem; padding: .4rem .7rem; margin-right: .4rem;
           border: 0; border-radius: .3rem; background: #2f6bd8;
           color: #fff; cursor: pointer; }}
 button.neg {{ background: #6b3030; }}
 button.ok {{ background: #2f7a45; }}
 .locked {{ color: #ff8b8b; }}
 .curfew {{ color: #ffc46b; margin: .2rem 0; font-size: .95rem; }}
 form {{ display: inline; }}
 /* Week x 24h grid. The horizontal scroller is for narrow phones: 24
    columns cannot shrink below legibility, so let it overflow rather
    than collapse into unreadable slivers. */
 .calwrap {{ overflow-x: auto; margin: .6rem 0 .2rem; }}
 .cal {{ display: grid; grid-template-columns: 2.2rem repeat(24, 1fr) 2.4rem;
         gap: 1px; min-width: 22rem; }}
 .cal > div {{ height: 1rem; }}
 .cal .hh {{ font-size: .55rem; color: #7d8794; text-align: left;
             line-height: 1rem; }}
 .cal .dl {{ font-size: .7rem; color: #9aa4b2; line-height: 1rem; }}
 .cal .dl.today {{ color: #e6e6e6; font-weight: 600; }}
 .cal .bd {{ font-size: .6rem; color: #7d8794; line-height: 1rem;
             text-align: right; }}
 .cal .on {{ background: #2f6bd8; }}
 .cal .off {{ background: #262a33; }}
 .cal .now {{ outline: 2px solid #ffc46b; outline-offset: -2px; }}
 .legend {{ font-size: .75rem; }}
 .sw {{ display: inline-block; width: .7rem; height: .7rem;
        vertical-align: -1px; margin: 0 .2rem 0 .5rem; }}
 .sw.on {{ background: #2f6bd8; }}
 .sw.off {{ background: #262a33; }}
 .sw.now {{ background: #262a33; outline: 2px solid #ffc46b;
            outline-offset: -2px; }}
</style></head><body>
<h1>screen time &middot; {now.strftime('%A %Y-%m-%d %H:%M')}</h1>
{''.join(rows)}
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "timekpr-central"
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        self._body = None
        super().__init__(*args, **kwargs)

    def handle_one_request(self):
        # Reset per REQUEST, not per connection: keep-alive reuses one
        # handler instance for many requests, so a body cached from the
        # previous one would leak into this one.
        self._body = None
        super().handle_one_request()

    @property
    def controller(self):
        return self.server.controller

    def log_message(self, fmt, *args):
        # journald already timestamps; keep one terse line per request.
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _respond(self, status, body, content_type="text/plain; charset=utf-8",
                 extra_headers=()):
        payload = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for key, value in extra_headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, status, payload):
        self._respond(status, json.dumps(payload), "application/json")

    def _drain_body(self):
        """Consume the request body exactly once, before any response.

        This MUST happen even on the rejection paths. We speak HTTP/1.1, so
        the connection is kept alive; a body left unread stays in the socket
        buffer and the next read parses it as a request line ("Bad request
        syntax ('host=…&user=…')"), desynchronising the connection. An early
        `return` after sending 401 is precisely how that happens.
        """
        if self._body is not None:
            return self._body
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        # These requests carry a handful of form fields; anything larger is
        # a mistake or an attempt to make us allocate.
        length = max(0, min(length, MAX_BODY_BYTES))
        self._body = self.rfile.read(length) if length else b""
        return self._body

    def _form(self):
        raw = self._drain_body().decode("utf-8", "replace")
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

    def _require_basic_auth(self):
        """True if the request carries the parent's credentials.

        Fails CLOSED when no password file is present: the dashboard can
        grant time, and this box sits on the same LAN as the kids' laptops.
        """
        expected = self.controller.admin_password
        if not expected:
            self._respond(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "dashboard password not provisioned on this host\n",
            )
            return False
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                decoded = base64.b64decode(header[6:]).decode("utf-8", "replace")
            except (ValueError, UnicodeDecodeError):
                decoded = ""
            user, _, password = decoded.partition(":")
            if hmac.compare_digest(user, self.controller.admin_user) and \
               hmac.compare_digest(password, expected):
                return True
        self._respond(
            HTTPStatus.UNAUTHORIZED,
            "auth required\n",
            extra_headers=[("WWW-Authenticate", 'Basic realm="screen time"')],
        )
        return False

    def _require_token(self):
        """True if the agent presented the shared bearer token.

        No token configured => open. That is deliberate: the monotonic
        `max()` update means an unauthenticated reporter cannot grant
        itself time, so the token is hardening rather than the primary
        control, and the system stays usable before it is provisioned.
        """
        expected = self.controller.token
        if not expected:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer ") and \
           hmac.compare_digest(header[7:].strip(), expected):
            return True
        self._json(HTTPStatus.UNAUTHORIZED, {"error": "bad token"})
        return False

    def do_GET(self):
        self._drain_body()
        path = urllib.parse.urlparse(self.path).path
        if path == "/health":
            self._respond(HTTPStatus.OK, "ok\n")
        elif path == "/":
            if self._require_basic_auth():
                self._respond(
                    HTTPStatus.OK,
                    render_dashboard(self.controller, datetime.now()),
                    "text/html; charset=utf-8",
                )
        elif path == "/status":
            if self._require_basic_auth():
                now = datetime.now()
                self._json(HTTPStatus.OK, {
                    u: self.controller.status(u, now)
                    for u in sorted(self.controller.users)
                })
        else:
            self._respond(HTTPStatus.NOT_FOUND, "not found\n")

    def do_POST(self):
        # Drain BEFORE dispatch so every rejection path below is safe to
        # `return` from without desynchronising the keep-alive connection.
        self._drain_body()
        path = urllib.parse.urlparse(self.path).path
        if path == "/report":
            self._handle_report()
        elif path == "/grant":
            self._handle_grant()
        elif path == "/lock":
            self._handle_lock(True)
        elif path == "/unlock":
            self._handle_lock(False)
        else:
            self._respond(HTTPStatus.NOT_FOUND, "not found\n")

    def _handle_report(self):
        if not self._require_token():
            return
        form = self._form()
        username = form.get("user", "")
        host = form.get("host", "")
        try:
            spent = int(form.get("spent", ""))
        except ValueError:
            self._json(HTTPStatus.BAD_REQUEST, {"error": "spent must be an integer"})
            return
        if not username or not host or spent < 0:
            self._json(HTTPStatus.BAD_REQUEST, {"error": "user, host, spent required"})
            return
        now = datetime.now()
        if self.controller.budget_seconds(username, now) is None:
            self._json(HTTPStatus.NOT_FOUND, {"error": f"unknown user {username}"})
            return
        self.controller.store.record(now.strftime("%Y-%m-%d"), username, host, spent)
        self._json(HTTPStatus.OK, self.controller.status(username, now))

    def _handle_grant(self):
        if not self._require_basic_auth():
            return
        form = self._form()
        username = form.get("user", "")
        try:
            minutes = int(form.get("minutes", ""))
        except ValueError:
            self._respond(HTTPStatus.BAD_REQUEST, "minutes must be an integer\n")
            return
        now = datetime.now()
        if self.controller.budget_seconds(username, now) is None:
            self._respond(HTTPStatus.NOT_FOUND, f"unknown user {username}\n")
            return
        self.controller.store.add_bonus(
            now.strftime("%Y-%m-%d"), username, minutes * 60
        )
        self._respond(
            HTTPStatus.SEE_OTHER, "", extra_headers=[("Location", "/")]
        )

    def _handle_lock(self, lock):
        """POST /lock and /unlock. Parent action, so basic auth, not token."""
        if not self._require_basic_auth():
            return
        form = self._form()
        username = form.get("user", "")
        now = datetime.now()
        if self.controller.budget_seconds(username, now) is None:
            self._respond(HTTPStatus.NOT_FOUND, f"unknown user {username}\n")
            return
        if lock:
            try:
                minutes = int(form.get("minutes", "0") or 0)
            except ValueError:
                self._respond(HTTPStatus.BAD_REQUEST, "minutes must be an integer\n")
                return
            until = now + timedelta(minutes=minutes) if minutes > 0 else None
            self.controller.store.set_lock(username, until)
        else:
            self.controller.store.clear_lock(username)
        # Browsers post these from the dashboard; agents and scripts get the
        # same route, so answer 303 for the former and let curl -L follow.
        self._respond(
            HTTPStatus.SEE_OTHER, "", extra_headers=[("Location", "/")]
        )


def main():
    if len(sys.argv) != 2:
        print("usage: timekpr-central <spec.json>", file=sys.stderr)
        return 2
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        spec = json.load(fh)

    os.makedirs(spec["stateDir"], mode=0o700, exist_ok=True)
    controller = Controller(spec)
    if not controller.admin_password:
        print(
            "timekpr-central: no dashboard password readable — the dashboard "
            "will refuse every request until one is provisioned",
            file=sys.stderr,
        )

    httpd = ThreadingHTTPServer((spec.get("bind", "0.0.0.0"), spec["port"]), Handler)
    httpd.controller = controller
    print(
        f"timekpr-central: listening on {spec.get('bind', '0.0.0.0')}:{spec['port']} "
        f"for users {', '.join(sorted(controller.users))}",
        file=sys.stderr,
    )
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
