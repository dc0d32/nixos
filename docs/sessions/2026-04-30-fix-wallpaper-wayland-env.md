# 2026-04-30 — Fix gray wallpaper after boot (Wayland env propagation)

## Goal

After a fresh `nixos-rebuild switch` and reboot on `pb-x1`, niri came
up with a flat gray background instead of the rotating Wallhaven
wallpaper. `awww-daemon.service` was in `failed (start-limit-hit)`
state in the user manager, and `easyeffects.service` was failing the
same way at the same boot timestamp. `~/.wallpaper/` had a fresh
collection of JPEGs from the previous evening's timer runs, then
nothing after the post-reboot graphical-session start — so the timer
itself was running, just not finding a daemon to talk to.

## Context

`awww` uses a small Wayland client baked into its daemon to claim the
background layer; the daemon needs `WAYLAND_DISPLAY` set in its
environment to find the compositor socket. On this host it's started
by a user systemd unit `WantedBy=graphical-session.target` —
specifically:

```
PartOf=graphical-session.target
After=graphical-session.target
```

Reproduced the failure precisely on the live machine:

```sh
env -u WAYLAND_DISPLAY -u XDG_CURRENT_DESKTOP \
  /nix/store/…-awww-daemon-…/bin/awww-daemon
# → SIGABRT in awww_daemon::wayland::connect
#   (daemon/src/wayland.rs:60)
```

`systemctl --user show-environment` on the live session confirmed
`WAYLAND_DISPLAY` was missing from the user manager's env block. So:

- niri starts.
- niri activates `graphical-session.target`.
- systemd starts `awww-daemon.service` (and `easyeffects.service`,
  and anything else `WantedBy=graphical-session.target`).
- All those units inherit the user manager's environment, which has
  no `WAYLAND_DISPLAY`.
- They crash on first Wayland connect.
- systemd retries (default `Restart=on-failure`) but the default
  `StartLimitBurst=5 / StartLimitIntervalSec=10s` with default
  `RestartSec=100ms` means the unit gives up in well under a second.
- By the time niri's later `spawn-at-startup` chain (bitwarden,
  hyprpolkitagent, easyeffects, quickshell) runs anything that
  *would* push the env, the affected units are already dead.

niri does not natively run `dbus-update-activation-environment` or
`systemctl --user import-environment` at session start. sway and
hyprland ship recipes for this; niri-flake leaves it to the user.

The fix is the same recipe everyone else uses: have the compositor
spawn `dbus-update-activation-environment --systemd …` as the very
first thing it does after coming up, so D-Bus-activated services and
the user systemd manager both learn the Wayland env vars before any
graphical-session unit gets a chance to start.

## Implementation

Three changes, one commit, all in the homeManager class:

### 1. `flake-modules/niri.nix` — env propagation

Added a `spawn-at-startup` entry via `lib.mkBefore` so it runs FIRST,
before all the other niri-spawned helpers (bitwarden, polkit-agent,
easyeffects, quickshell — which all depend on the env having been
pushed):

```nix
programs.niri.settings.spawn-at-startup = lib.mkBefore [
  {
    command = [
      "${pkgs.dbus}/bin/dbus-update-activation-environment"
      "--systemd"
      "WAYLAND_DISPLAY"
      "XDG_CURRENT_DESKTOP"
    ];
  }
];
```

`--systemd` is what tells dbus-update-activation-environment to also
push into `systemctl --user` (otherwise it only updates D-Bus). The
two variables are the minimum useful set: `WAYLAND_DISPLAY` (the
obvious one) and `XDG_CURRENT_DESKTOP` (used by xdg-portal backend
selection, gtk theming, and per-compositor branches in many apps).

Verified the rendered `~/.config/niri/config.kdl` from the new HM
closure has this line FIRST in the spawn-at-startup block:

```
spawn-at-startup "/nix/store/…/dbus-update-activation-environment" "--systemd" "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP"
spawn-at-startup ".../bitwarden" "--silent"
spawn-at-startup ".../hyprpolkitagent"
spawn-at-startup "easyeffects" "--gapplication-service"
spawn-at-startup "quickshell"
```

### 2. `flake-modules/wallpaper.nix` — awww-daemon unit hardening

Even with the env-import in place, there is still a brief race
window: niri spawns the dbus call as a child process; that call
returns asynchronously; meanwhile graphical-session.target is being
activated in parallel and pulling in awww-daemon. If awww-daemon
loses the race, default systemd retry behaviour gives up in under a
second (5 restarts × 100ms = <1s), well before the env-import
finishes.

```nix
Unit = {
  StartLimitBurst = 10;
  StartLimitIntervalSec = 60;
};
Service = {
  RestartSec = 2;
  # …existing Restart=on-failure, ExecStart, etc.
};
```

10 restarts spaced 2s apart gives the daemon up to ~20s of headroom
to ride out a slow env-import, while still being snappy enough that
the user doesn't see a noticeable gray-screen window on a normal
boot.

### 3. `flake-modules/wallpaper.nix` — wallpaper-fetch socket poll

The timer's `wallpaper-fetch.service` already has
`Wants=awww-daemon.service` + `After=awww-daemon.service` in its
unit. That guarantees ORDER, not READINESS — a `Type=simple` unit is
considered "started" the instant `exec()` returns, well before
awww-daemon has finished negotiating with the compositor and bound
its IPC socket.

So even when the daemon was healthy, the very first
`wallpaper-fetch` instance after boot could fire, download an image,
then have `awww img` fail with "Socket file '…wayland-1-awww-daemon.sock'
not found" — wasting the fetch and leaving no current symlink.

Added a 30-second poll loop at the top of the script:

```sh
sock="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY-awww-daemon.sock"
for _ in $(seq 1 30); do
  [ -S "$sock" ] && break
  sleep 1
done
if [ ! -S "$sock" ]; then
  echo "wallpaper-fetch: awww-daemon socket $sock did not appear within 30s; bailing" >&2
  exit 0
fi
```

Bails with `exit 0` rather than failure — the next timer tick
(default 30 minutes later) will retry, and in the pathological case
where awww-daemon is genuinely broken we don't want a failed unit
masking the real problem nor do we want to burn through quota
hammering wallhaven.

## Verified

```sh
nix build .#nixosConfigurations.pb-x1.config.system.build.toplevel
# /nix/store/s6nhvv2s4j9kkh14a6k7saj8kkksa5fh-nixos-system-pb-x1-25.11.20251023.b8df4a4
nix build .#nixosConfigurations.family-laptop.config.system.build.toplevel
# /nix/store/8w8lx5qwvbkf56vpz44j4ysfxi5lgcys-nixos-system-family-laptop-…
nix build .#nixosConfigurations.wsl.config.system.build.toplevel
# /nix/store/f8pc9csn7cp1qzcx753cp80ny7wjb141-nixos-system-wsl-…
```

All three NixOS systems byte-identical to baseline (changes are
HM-only).

```sh
nix build .#homeConfigurations.'p@pb-x1'.activationPackage
# /nix/store/cljghrv6xh7ihs5dihab646k2s3llpsw-home-manager-generation
nix build .#homeConfigurations.'p@family-laptop'.activationPackage
# /nix/store/zy1xnnp7k3x2b9gk138nyxk7q84b9drl-home-manager-generation
nix build .#homeConfigurations.'m@family-laptop'.activationPackage
# /nix/store/yzwmq2x44iczd088ddb60zi4qpcizjki-home-manager-generation
nix build .#homeConfigurations.'s@family-laptop'.activationPackage
# /nix/store/6bbh6jzs11v2f7bdwzh6wvh233sp6s27-home-manager-generation
```

p@ HM closures changed (expected — niri config + wallpaper unit edits
are HM-class). m@ and s@ also rebuilt clean (they import niri but not
wallpaper; the env-import propagates to all niri users).

`nix flake check` clean. `nix fmt` clean.

Live verification on `pb-x1` happens after the user runs
`home-manager switch --flake .#'p@pb-x1'` and re-enters the niri
session (no reboot needed; the env-import only kicks in on next niri
session start).

## Files

Modified:

- `flake-modules/niri.nix` — added env-import spawn-at-startup
  (mkBefore) in the homeManager class.
- `flake-modules/wallpaper.nix` — added socket-poll guard to
  `wallpaper-fetch` script and start-limit hardening to
  `awww-daemon` unit.

New:

- `docs/sessions/2026-04-30-fix-wallpaper-wayland-env.md` (this file).

## Side-effects

The env-import incidentally fixes `easyeffects.service` failing the
same way at boot (same root cause — it's another graphical-session-
bound user unit that needs `WAYLAND_DISPLAY`). No explicit changes
were made to easyeffects; it inherits the fix. Worth checking after
the next boot that easyeffects loads its preset cleanly without the
manual systemctl restart that was previously necessary.

## Open / future

- **Race never fully closed**: niri spawns the env-import as a
  detached child, so even with `mkBefore` ordering and the
  start-limit hardening, there is a theoretical window where a
  graphical-session unit could observe stale env. The hardening is
  defense-in-depth. If we ever see awww-daemon hit the 10-restart
  limit in practice, the next escalation is to add an explicit
  `After=` on a oneshot unit that wraps the env-import — i.e. move
  it out of niri's spawn-at-startup (best-effort) and into a real
  systemd dependency edge (guaranteed before).
- **niri upstream**: there's an open discussion about niri shipping
  systemd env import natively at session start. When that lands,
  the spawn-at-startup entry becomes redundant and should be
  removed (retirement condition documented in the module).
- **Other compositor users**: `m@family-laptop` and `s@family-laptop`
  also import niri via the cross-class module. They get the
  env-import for free (shared homeManager.niri module) but neither
  imports `wallpaper`, so the awww-daemon hardening is a no-op
  there. Confirmed both HM closures still build clean.

## Follow-up (same session, after live verification)

After `home-manager switch` and a niri re-login, two issues
surfaced that needed follow-on commits.

### easyeffects double-start (commit `a9ac936`)

Predicted side-effect (env-import unblocks easyeffects.service) was
**wrong** — the unit was still failing, but with a different
signature than before:

```
Process: 10765 ExecStart=…/easyeffects --hide-window (code=exited, status=0/SUCCESS)
…
easyeffects.service: Scheduled restart job, restart counter is at 10.
easyeffects.service: Start request repeated too quickly.
easyeffects.service: Failed with result 'start-limit-hit'.
```

10 successful exits in <2 seconds — not a Wayland crash. `pgrep`
revealed the smoking gun:

```
11009 easyeffects --gapplication-service
```

That process was launched by niri spawn-at-startup
(`flake-modules/quickshell.nix:46`, ironically inside the quickshell
module). The systemd unit defined in `flake-modules/audio.nix:155`
also tries to launch easyeffects (`--hide-window`). The
niri-spawned process won the race and claimed the unique-name on
the session bus; the systemd unit's invocation found the primary
already there, handed off as a remote-control client, and exited
status=0 in ~170ms. Combined with `Restart=always` (correct for the
DSP supervision use case), systemd loops and trips StartLimitBurst.

**Fix**: drop the spawn-at-startup line; the systemd unit is the
canonical owner per audio.nix's design comments (it IS the primary
GApplication, owns the unix socket, runs DSP, restarts on
suspend/resume disconnects). One owner, no race.

The bug was pre-existing — easyeffects had been failing every
session — but was masked by the fact that the niri-spawned daemon
was actually doing the audio work. The user only noticed because
the post-wallpaper-fix verification surfaced the failed unit.

After commit `a9ac936` + activation:
- killed orphan `easyeffects --gapplication-service` (PID 11009).
- `Restart=always` immediately spawned a replacement under the
  systemd unit (PID 23187).
- `systemctl --user status easyeffects` shows active running, single
  PID, owned by `easyeffects.service`.

### Python IndentationError in fetch script (commit `a0fcef9`)

Pre-commit `nix fmt` (nixpkgs-fmt) on the wallpaper.nix changes in
`0007775` rebalanced indentation inside the Nix indented-string
literal that holds the fetch script. The Python heredoc body
passed to `python3 -c "…"` ended up 2 columns deeper than the
surrounding shell statements. Nix's indented-string strip removes
the **minimum common leading whitespace**, so those 2 columns
survived into the rendered script:

```sh
$ cat /nix/store/…-wallpaper-fetch
…
json=$(/nix/store/…/curl -fsSL "$api")

  # Pick a random result from the page and extract its image URL
  img_url=$(echo "$json" | /nix/store/…/python3 -c "
  import json, sys, random       # ← 2 leading spaces, Python errors
  …
```

First post-`home-manager switch` timer fire failed with:

```
IndentationError: unexpected indent
wallpaper-fetch.service: Failed with result 'exit-code'.
```

**Fix**: re-indent lines 71-94 to match the surrounding heredoc
body (8 spaces, not 10), and add an in-source NOTE comment warning
future formatters/maintainers off the python heredoc indent.

After commit `a0fcef9` + activation + manual trigger:
- `wallpaper-fetch.service` exited status=0/SUCCESS in 178ms.
- `~/.wallpaper/20260501-075113.jpg` fetched, `current.jpg`
  updated.
- `systemctl --user is-system-running` reports `running` (was
  `degraded` before the fix).

### Lesson

`nix fmt` does not understand semantics inside Nix indented
strings. When such a string contains a whitespace-significant
embedded language (Python, YAML, Makefile, here-doc-passed shell),
formatter-induced re-indentation can silently shift the rendered
content and break it at runtime. Two mitigations going forward:

1. Keep entire heredoc bodies at one consistent indent level,
   matching the surrounding statements. Mixed indent levels inside
   the heredoc are a footgun because nixpkgs-fmt may rebalance
   them in surprising ways.
2. Add a NOTE comment immediately above any whitespace-significant
   embedded block, naming the formatter trap explicitly. Done in
   `wallpaper.nix` for the python heredoc.

A more thorough fix would be to extract embedded languages into
their own files (`pkgs.writeText` or out-of-band) so the formatter
never sees them. Not done here because the python is 5 lines and
extraction would be heavier than the inline footgun. Consider it
if any embedded block grows past ~20 lines.

### Updated commit list

- `0007775` — niri env-import + awww-daemon hardening +
  wallpaper-fetch socket poll. (Introduced the python indent bug.)
- `a9ac936` — drop duplicate easyeffects spawn-at-startup (the
  systemd unit is the canonical owner).
- `a0fcef9` — fix python IndentationError in fetch script
  (re-indent heredoc body, add NOTE comment).
