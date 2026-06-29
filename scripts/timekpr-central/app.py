"""Timekpr central control plane: shared cross-host daily budget + dashboard.

Agents on each host POST consumed seconds; the server sums usage across
hosts and returns the per-user remaining = budget + grant - total_consumed.
Each host sets that remaining locally, so the budget is shared. Enforcement
stays local; an offline host just keeps its last local cap. Basic-auth dash.
"""
import os
import sqlite3
import datetime
import secrets
from contextlib import closing
from fastapi import FastAPI, HTTPException, Depends, Form
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse

DB = os.environ.get("TIMEKPR_DB", "/data/timekpr.db")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "changeme")
# Weekday budgets in minutes: Mon..Sun. Override via env BUDGET_WEEKDAY/WEEKEND.
WD = int(os.environ.get("BUDGET_WEEKDAY", "240"))
WE = int(os.environ.get("BUDGET_WEEKEND", "360"))
BUDGET_MIN = [WD, WD, WD, WD, WD, WE, WE]
USERS = [u for u in os.environ.get("KIDS", "m,s").split(",") if u]

app = FastAPI()
basic = HTTPBasic()


def today():
    return datetime.date.today().isoformat()


def budget_sec(day=None):
    d = datetime.date.fromisoformat(day) if day else datetime.date.today()
    return BUDGET_MIN[d.weekday()] * 60


def db():
    c = sqlite3.connect(DB)
    c.execute("CREATE TABLE IF NOT EXISTS usage(host TEXT,user TEXT,day TEXT,consumed INT,ts TEXT,PRIMARY KEY(host,user,day))")
    c.execute("CREATE TABLE IF NOT EXISTS grant_(user TEXT,day TEXT,extra INT,PRIMARY KEY(user,day))")
    return c


def consumed_total(c, user, day):
    r = c.execute("SELECT COALESCE(SUM(consumed),0) FROM usage WHERE user=? AND day=?", (user, day)).fetchone()
    return r[0]


def grant_extra(c, user, day):
    r = c.execute("SELECT extra FROM grant_ WHERE user=? AND day=?", (user, day)).fetchone()
    return r[0] if r else 0


def remaining(c, user, day):
    return max(0, budget_sec(day) + grant_extra(c, user, day) - consumed_total(c, user, day))


def auth(cred: HTTPBasicCredentials = Depends(basic)):
    ok = secrets.compare_digest(cred.username, ADMIN_USER) and secrets.compare_digest(cred.password, ADMIN_PASS)
    if not ok:
        raise HTTPException(401, headers={"WWW-Authenticate": "Basic"})
    return True


@app.post("/report")
def report(host: str = Form(...), user: str = Form(...), consumed: int = Form(...)):
    """Agent reports this host's consumed seconds; returns shared remaining."""
    d = today()
    with closing(db()) as c:
        c.execute("INSERT INTO usage(host,user,day,consumed,ts) VALUES(?,?,?,?,?) "
                  "ON CONFLICT(host,user,day) DO UPDATE SET consumed=excluded.consumed,ts=excluded.ts",
                  (host, user, d, max(0, consumed), datetime.datetime.now().isoformat()))
        c.commit()
        return {"user": user, "remaining": remaining(c, user, d), "budget": budget_sec(d)}


@app.get("/", response_class=HTMLResponse)
def dash(_: bool = Depends(auth)):
    d = today()
    rows = ""
    with closing(db()) as c:
        for u in USERS:
            tot, rem, g = consumed_total(c, u, d), remaining(c, u, d), grant_extra(c, u, d)
            bud = budget_sec(d)
            pct = min(100, 100 * tot // bud) if bud else 0
            hosts = "".join(f"<li>{h}: {cs//60}m</li>" for h, cs in
                            c.execute("SELECT host,consumed FROM usage WHERE user=? AND day=?", (u, d)))
            rows += (f"<div class=k><h2>{u}</h2><div class=bar><i style='width:{pct}%'></i></div>"
                     f"<p>{tot//60}m used / {bud//60}m budget (+{g//60}m granted) — <b>{rem//60}m left</b></p>"
                     f"<ul>{hosts}</ul><form method=post action=/grant>"
                     f"<input type=hidden name=user value={u}>"
                     f"<button name=mins value=15>+15m</button><button name=mins value=30>+30m</button>"
                     f"<button name=mins value=-9999>lock now</button></form></div>")
    return f"<html><head><title>timekpr</title><style>body{{font:14px sans-serif;max-width:600px;margin:2em auto}}.k{{border:1px solid #ccc;border-radius:8px;padding:1em;margin:1em 0}}.bar{{background:#eee;height:14px;border-radius:7px}}.bar i{{display:block;height:14px;background:#4a90d9;border-radius:7px}}</style></head><body><h1>Screen time — {d}</h1>{rows}</body></html>"


@app.post("/grant")
def grant(user: str = Form(...), mins: int = Form(...), _: bool = Depends(auth)):
    with closing(db()) as c:
        c.execute("INSERT INTO grant_(user,day,extra) VALUES(?,?,?) "
                  "ON CONFLICT(user,day) DO UPDATE SET extra=extra+?",
                  (user, today(), mins * 60, mins * 60))
        c.commit()
    return RedirectResponse("/", 303)


@app.get("/health")
def health():
    return JSONResponse({"ok": True})
