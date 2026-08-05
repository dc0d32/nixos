# 2026-08-04 — Discovery: `guide` / `tip`

## The problem

> "We installed so many cool things on my kids' machines, but they don't
> know of it."

m and s (pb-t480, m-pc) carry the full niri desktop, the screenshot /
clipboard / recording pipeline, FreeCAD, Fritzing + CircuitJS, VS Code,
the hardware-hacking flashing kit (and the `dialout`/`plugdev`
membership to use it without sudo), `copilot` + `opencode`, and ~40
terminal tools from the base/dev bundles. None of that was ever
announced.

Every discovery surface that existed was **pull-only**:

| Surface | Why it wasn't enough |
| --- | --- |
| `tools` → `terminal-help.md` | you must already know the word `tools` |
| `Mod+Shift+/` (niri hotkey overlay) | `skip-at-startup = true`, and **1 of 123** binds had a `hotkey-overlay.title` — the rest rendered as raw action names (`switch-focus-between-floating-and-tiling`) |
| fuzzel | only shows things that ship a `.desktop` file |

A doc nobody opens is a doc that doesn't exist. So the fix had to add a
**push** surface, not just a better page.

## What was built

New `flake-modules/discovery.nix` (HM module `discovery`), added to the
`home-desktop` and `home-kid` bundles. Four layers:

1. **`guide`** — the cheat sheet. Reachable from `Mod+Slash`, a `?`
   button in waybar, "Help & Tips" in fuzzel, or typing `guide`.
2. **`tip`** — one tip per day, pushed as a mako notification at login
   (`discovery-tip.service`) and as a zsh greeting line.
3. **`hotkey-overlay.title` backfill** across `niri/binds.nix` and
   `displays.nix` — ~45 binds named in language a 12-year-old reads.
4. **zsh greeting** — `tip --daily` on the first interactive shell of
   the day.

## Decisions worth keeping

### The `hotkey-overlay.title` does double duty

A bind appears in the generated cheat sheet **iff it carries a
`hotkey-overlay.title`**. That one attribute is simultaneously:

- the human label niri's own `Mod+Shift+/` overlay shows, and
- discovery.nix's curation marker.

So the cheat sheet is *generated from the binds table* and cannot drift
from it — and the ~80 mechanical navigation variants stay untitled,
out of the kid-facing table, still reachable via the overlay. Adding a
bind worth knowing about is exactly "give it a title", nothing else.

Binds sharing one title collapse onto a single row, so the arrow-key
and vim-key forms of one action get the *same* title and render as
``​`Mod+H` · `Mod+Left` | Focus the window to the left``.

Group headings ("Windows & layout", "Workspaces", …) are derived from
the *action name* (`focus-workspace-down` → Workspaces), with a small
override table for the handful of binds whose action name lies about
their purpose — a `spawn` of the screenshot wrapper is a screenshot,
not an app launch. A stale override is harmless: it's simply never read.

### Tips are probe-gated at runtime, not eval time

Each tip carries a `probe` command; the guide emits
`if command -v freecad …` around that tip's heredoc. A kid without
FreeCAD never sees the FreeCAD tip, and discovery.nix never has to know
which bundle anyone is on. Verified: with `PATH=/run/current-system/sw/bin`
the FreeCAD/KiCad/copilot tips vanish; with p's PATH they appear.

Section headings are dropped when every tip under them failed its probe,
so nobody gets an empty "Making things" header.

### One daily stamp, committed only on delivery

The login notification and the shell greeting share
`$XDG_STATE_HOME/discovery/last-tip`, so a kid gets the tip from
whichever surface they reach first — never both, never twice.

The stamp is **checked** up front but **committed only after the tip was
actually delivered**. The first version committed on entry, which meant
a login-time `notify-send` that failed (no notification daemon up yet,
headless session) silently ate that day's tip for the shell greeting
too and the kid saw nothing at all. Verified by running
`--notify-daily` with `DBUS_SESSION_BUS_ADDRESS` pointed at nothing:
notify fails, no stamp written, greeting still delivers.

Tip selection is `(day-of-year + cksum(username)) % count`. Stable all
day, rotates daily, and the username offset stops two kids on the same
machine seeing the identical tip on the identical day (verified: m, s
and p each get a different tip today).

First run ever shows a welcome card instead of a random tip — otherwise
the very first thing they see is a tip about one tool, with no hint that
a whole page of them exists.

## Traps hit

- **`programs.waybar.settings` is `types.anything`, and `anything` does
  NOT concatenate lists.** Two modules both defining `modules-right` is
  an *eval error*, not a merge (confirmed with a standalone
  `lib.evalModules` probe). The `custom/help` button therefore lives in
  `desktop-shell.nix`, not in `discovery.nix`.
- **`a && b && exit 0` under `set -e`.** `writeShellApplication` runs
  `set -euo pipefail`; a top-level `&&` chain whose first test fails
  makes the *whole command* non-zero and kills the script. The daily
  gate is written as a plain `if`.
- **shellcheck SC2016 fails the build on backticks in single quotes.**
  A `printf '… `guide` …'` in the tip text was a hard build failure —
  and shellcheck then crashed trying to print the offending line,
  because it contained an emoji (`commitBuffer: invalid argument`), so
  the real diagnostic was nearly invisible.
- **The tty test for "should I open a terminal?" needs stdin as well as
  stdout.** `guide` re-execs itself inside alacritty when it has no
  terminal. Testing stdout alone means `guide | head` or
  `guide > out.md` typed at a shell pops an alacritty window instead of
  writing to the pipe — which is exactly what happened the first time it
  was run. A launcher / bar / systemd invocation has neither stdin nor
  stdout on a tty; a shell pipeline still has stdin.
- **mako's default left-click is `invoke-default-action`**, so the
  notify-send action MUST be named `default` for a plain click to open
  the guide. `-A show="…"` would render a button that does nothing.

## Deliberately not done

- **niri's hotkey overlay still has `skip-at-startup = true`.** Showing
  it on every login is a tax on p forever to teach the kids once, and
  niri only has a global boolean. The first-run welcome notification is
  the controllable version of the same idea.
- **No screen-time-remaining tip.** The kids can't query their own
  timekpr budget without being in the `timekpr` group, and widening that
  group is a policy change, not a discovery change. Worth revisiting —
  "how much time do I have left" is the question they actually ask.

## Verified

- `nix flake check` — all checks passed (pure, no `--impure`).
- All 8 buildable HM configs build. `p@pb-mb` fails as before (an
  aarch64-darwin config can't build on x86_64-linux) — confirmed
  pre-existing by stashing the change.
- `guide` renders 363 lines of Markdown; styled correctly under glow on
  a pty, plain when piped.
- `tip` verified for: welcome-on-first-run, silence on the second run
  the same day, per-user rotation, probe filtering, and no stamp
  consumption when the notification fails.

## Files

| File | Change |
| --- | --- |
| `flake-modules/discovery.nix` | new — `guide`, `tip`, desktop entry, `Mod+Slash`, `discovery-tip.service`, zsh greeting |
| `flake-modules/desktop-shell.nix` | `custom/help` waybar button + CSS |
| `flake-modules/niri/binds.nix` | ~40 `hotkey-overlay.title`s + header explaining their double duty |
| `flake-modules/displays.nix` | titles on `Mod+D` / `Mod+Shift+D` |
| `flake-modules/bundles/home-base.nix` | import `discovery` (see phase 2) |
| `flake-modules/terminal-help.md` | cross-link to `guide` |
| `AGENTS.md`, `README.md` | document the invariants below |

---

# Phase 2 — same session: make it p's too

> "even I forget things sometimes. Be nice to have this for p too."

p already *had* `guide`/`tip` — `discovery` was in the `home-desktop`
bundle, so all three desktop hosts carried it. Two things were actually
missing.

## Missing thing 1: content aimed at p

None of the tips covered this flake's own operating surface. Added a
`admin` section — ten tips on the stuff that fires once a quarter and is
therefore forgotten by the person who wrote it:

- `auto-update-status` / `sudo auto-update-now` / stopping the timer
- `backup-snapshots` / `backup-restore --include` / `seed-from-host.sh`
- the `Mod+D` → `Mod+Shift+D` → `display-export` → `display-reset` loop
  for promoting a monitor layout back into the flake
- the rebuild commands, including **`nix fmt .` needing the path
  argument** and the standing "never add `--impure` to CI" rule
- rolling back (both `--rollback` and the 30-day
  `/btrfs_tmp/old_roots/` archive on impermanent hosts)
- `timekpra`, plus the restatement of "budget and curfew window are
  independent axes" that looks like a bug every single time
- `biometrics-enroll`, and the deliberate no-face-unlock-on-lockscreen gap
- `hm_win` being a **separate** build from `home-manager switch`
- `audio-discover.sh`, and that `profile` is the PipeWire route
  description, not the ALSA card profile
- new files being invisible to nix until `git add`, plus the
  `nix fmt .`-recurses-into-`homelab/` scoping workaround

### These needed a second gate

Every one of those wrappers is installed **system-wide**, so they're on
m's and s's PATH too — `command -v backup-snapshots` succeeds for a kid.
A probe alone would have handed the kids a tour of the backup and
rollback machinery.

So tips gained `admin = true`, gated at runtime on wheel/admin
membership via `id -nG`, on top of the usual probe. macOS's `admin`
group is accepted alongside `wheel` so the same check works on pb-mb.

Verified by actually dropping groups (`unshare -Ur`, which leaves you
with `root nogroup`) rather than by shadowing `id` on PATH — the first
attempt at the latter silently did nothing, because
`writeShellApplication` prepends its `runtimeInputs` to PATH and
coreutils' `id` therefore wins. A 40-user sweep as a non-wheel user
leaked zero admin tips and still saw 23 distinct kid tips; the same
sweep as p surfaces 8 of the 10 admin tips on pb-x1 (the other two
probe `timekpra` and `hm_win`, which correctly aren't on that host).

## Missing thing 2: it didn't exist on p's headless hosts

`guide` was absent from `p@wsl`, `p@wsl-arm` and `p@pb-mb`, because
`discovery` read and contributed niri binds. Moved to the **base**
bundle and made portable:

- `hasNiri = options.programs ? niri` — the **declared-option** tree,
  not `config`. Testing `config.programs ? niri` while also defining
  `programs.niri.settings.binds` is a recursion.
- The keybind section, the `Mod+Slash` bind, the launcher entry, the
  login notification and the alacritty re-exec are all gated on it.
- The zsh greeting deliberately is **not** — on a headless host it's the
  only push surface there is.
- `libnotify` is only in `tip`'s `runtimeInputs` on Linux (verified
  absent from the darwin `tip.drv`, present in the WSL one), and
  `--notify` falls back to printing when `notify-send` is missing.

### Two recursion traps, in order

1. `lib.optionalAttrs hasNiri` at the module's **top level** is an
   infinite recursion. The module system has to read the returned
   attrset's KEYS — looking for `imports` / `options` / `config` —
   before it can finish building `options`, so a key set that depends on
   `options` eats itself. Fix: wrap the body in an explicit
   `config = { … };`, which gives the top level a fixed key set and
   defers `hasNiri` until config is demanded.
2. `mkIf false` is **not** a safe way to conditionally define an option
   that may not be declared — the unknown-option check still fires.
   `lib.optionalAttrs` genuinely omits the attribute, so it is.

## Also fixed in phase 2

Three desktop tips had `probe = null` and would have shown up on WSL
telling p to press `Mod+O`. Given real probes (`screenshot`, `niri`) —
consistent with the runtime-gating philosophy and cheaper than a
Nix-level condition.

## Verified (phase 2)

- `nix flake check` passes; all 8 buildable HM configs build.
- `p@pb-mb` (darwin) now *evaluates* `guide` and `tip` — checked via
  `nix eval` on `home.path.drvPath`, since it can't be built on
  x86_64-linux.
- WSL `guide` with a WSL-like PATH: no keybind section, no desktop
  tricks, no media section — Robot helpers, Terminal superpowers, and
  an admin section correctly reduced to `hm_win` and `git add`.
- Admin gating verified in both directions under a real group drop.

---

# Phase 3 — same session: it was too much about the terminal

> "remind them about AI tools, tinkering, physics simulation etc. as
> well. Not just terminal tools."

Fair. The first pass had 2 AI tips and 5 "making things" tips against 10
terminal tips, so the guide read like a shell tutorial with a workshop
appended.

Added 14 tips (26 → 49 total, 39 of them kid-visible), reordered the
sections so AI and making come before the terminal, and added a new
**🔬 Simulate & experiment** section.

## The unlock: almost nothing had to be installed

None of Blender, Godot, OpenSCAD, Sonic Pi, Krita, Inkscape, Step,
Stellarium, ngspice, gnuplot, Maxima or Octave is installed on any host,
and none of them now is. They don't need to be — `,` (comma, from
nix-index-database, already in the base bundle) fetches and runs any of
them for one session, and `nix run nixpkgs#<attr>` does it unambiguously
when several packages provide the same binary name.

So the load-bearing new tip is *"You can run almost any program ever
packaged, without installing it"*, with a concrete menu rather than the
abstract statement the old `,` tip made. It ends by inviting the reader
to ask for anything they use weekly to be installed properly, with a
launcher icon — which is the honest trade: `,` costs a slow first run
and gives you no `.desktop` entry.

Every package name and binary name in these tips was checked against
nixpkgs before being written down (`nix eval nixpkgs#<attr>.name` and
`nix-locate --minimal -w /bin/<cmd>`). Two results changed the copy:

- `step`, `godot`, `krita`, `octave`, `maxima`, `love` and `luanti` are
  **ambiguous** — several packages provide those binaries — so `,` would
  stop and ask. Those tips say `nix run nixpkgs#kdePackages.step` /
  `nix run nixpkgs#godot` instead, and the enabler tip explains *why*
  the picker appears.
- `geogebra6` produces no `bin/`, so GeoGebra is listed as a website
  rather than a command.

## The browser tips are not a cop-out

A whole tip is just websites — PhET, Wokwi, GeoGebra, Falstad,
Tinkercad. For a physics simulation or a virtual Arduino, "open Chrome"
genuinely beats a 2 GB download, and **wokwi.com** in particular closes a
loop the machine already has: prototype an ESP32 sketch against virtual
LEDs and sensors, then flash the identical code to the real board with
the `esptool`/`picocom` kit that's already installed and already in the
right groups.

## AI tips are now about *how to ask*

The two original AI tips just said "this exists". The three new ones are
about the difference between an AI that makes you better and one that
makes you helpless:

- **Make the AI explain it** — ask for two approaches and the
  trade-offs, ask it to quiz you, ask *"how would I check that
  myself?"* when it states a fact. It is confidently wrong sometimes and
  the tip says so.
- **Ask the AI about this computer itself** — `cd ~/nixos && copilot`,
  then *"where is the screenshot shortcut defined?"*. The whole machine
  is text files; nothing here is magic. Closes the loop with the guide's
  own footer ("if you want something added, it can be — ask").
- **Get the AI to write firmware for the board in your hand** (probes
  `picocom`, so it only appears where the hardware kit exists) — idea →
  code → a real LED doing a thing → it's wrong → paste the error back.

## Also

Deduplicated: the old terminal-section `,` tip and the new maker-section
one said the same thing. The terminal one was narrowed to the
command-not-found handler and now cross-references the other.

GUI-only tips probe `niri` so they don't appear on WSL; the maths and
notebook ones probe `nix-locate` / `uv` and do. Verified by rendering the
WSL guide under a WSL-like PATH.

## Verified (phase 3)

- 49 tips total, 10 admin-only. A 90-user sweep as a non-wheel user sees
  36 distinct tips and leaks zero admin ones.
- `nix flake check` passes; all 8 buildable HM configs build.
- WSL render correctly drops every GUI tip while keeping the AI, maths
  and notebook ones.

## Not done, deliberately

**Nothing new was installed.** Putting Blender + Godot + Krita +
Inkscape + Stellarium + Step on the kids' machines is a multi-GB closure
decision, and it changes what auto-update pulls down on every host — the
owner's call, not a side effect of a documentation change. The tips make
the try-it path a single command; promoting the ones that stick is a
one-line change to the kid bundle.

---

# Phase 4 — same session: rotate hourly

> "rotate tips every hour please"

Daily rotation meant a 49-tip catalogue took seven weeks to show itself
once. Now the **content** advances every hour.

## What changed

- The selector is `bucket = floor(epoch_seconds / 3600)` — hours since
  the epoch. UTC-based, so a DST change can't hand out the same hour
  twice or skip one, and it doesn't trip over month/year boundaries the
  way the old `%j` day-of-year did.
- **The same number drives both the gate and the rotation.** The stamp
  file stores the bucket; the index is derived from it. They cannot
  disagree, so there is no state where the tip has changed but the gate
  hasn't reopened (or vice versa).
- `--daily` / `--notify-daily` became `--once` / `--notify-once`. The
  flag no longer names the period, because the period is policy defined
  in one place.

## The index is a permutation, not `bucket % n`

Using the bucket directly would walk `avail` in file order — five AI
tips in a row, then six maker ones. The index is
`(bucket * 7919 + cksum(user)) % n` instead. 7919 is prime, so
`gcd(7919, n) = 1` for any plausible `n`, which makes `bucket → index` a
full-cycle permutation: **every tip is shown exactly once before any
repeats**, but consecutive hours land in unrelated sections. Verified —
38 distinct indices over 38 consecutive buckets, and the next ten hours
read physics → git → microcontrollers → AI → clipboard → art → file
manager → circuits → AI → screenshots.

## No hourly notification

Asked, and the answer was to rotate content hourly but keep the *popup*
at graphical login. A notification every hour on a laptop you use all
day is a tax, not a feature.

The practical effect is nicer than a timer anyway: the hourly surface is
the **shell greeting**, which only fires when you open a terminal. So a
fresh tip arrives when you're already at a keyboard and receptive, and
never interrupts. The login notification is the once-you-sit-down one,
and the shared stamp means whichever you hit first wins.

## The bug this phase uncovered

Verifying the new `tip --once` hook in the rendered `.zshrc` found it
**missing** — and it had been missing since phase 2.

Phase 2's structure was:

```nix
config = {
  home.packages = [ … ];
  programs.zsh.initContent = mkAfter "…";
} // lib.optionalAttrs hasNiri {
  xdg.desktopEntries.help-and-tips = { … };
  programs.niri.settings.binds."Mod+Slash" = { … };
  systemd.user.services.discovery-tip = { … };
};
```

`//` is a **shallow** update. Both blocks define something under
`programs.*`, so the second block's `programs` replaced the first's
entirely and the zsh greeting vanished. `home.packages` survived only
because `home` appears in one block.

It hid perfectly: on the headless configs `lib.optionalAttrs` yields
`{}`, so `p@wsl` was correct, and that's the config phase 2 was
scrutinising. Everything built, `nix flake check` passed, `guide` and
`tip` were both on PATH, and the only symptom was a silent absence four
lines long in a 259-line generated file.

Fixed with `lib.mkMerge`, which is what should have been used from the
start — it merges at the module level and cannot clobber. Now asserted
directly rather than by inspection:

```sh
nix eval --raw .#homeConfigurations.<cfg>.config.programs.zsh.initContent \
  | grep -c 'tip --once'      # 1 on m@pb-t480, p@pb-x1 AND p@wsl
```

Lesson worth keeping: when a module contributes to two option paths
under a shared prefix, `//` will silently eat one of them, and a build
that succeeds proves nothing.

## Verified (phase 4)

- zsh hook present in the *rendered* `.zshrc` (line 257) and in
  `config.programs.zsh.initContent` for `m@pb-t480`, `p@pb-x1` and
  `p@wsl`.
- Desktop-only outputs still land only where they should: `Mod+Slash`
  bind and `discovery-tip.service` present on `p@pb-x1`, absent on
  `p@wsl`, whose `xdg.desktopEntries` is `[ ]`.
- Gate behaviour: first run shows the welcome, a second run in the same
  hour is silent, rewinding the stamp by one bucket produces a different
  tip.
- All 8 buildable HM configs build; `nix flake check` passes.

---

# Phase 5 — same session: the guide wasn't rendering

> "clicking on the notification opens up a terminal with less showing
> the documentation but it doesn't render the markdown like it is
> supposed to"

## Root cause: a missing file extension

**glow decides whether to render a file as Markdown from its file
extension.** `guide` assembled its page into a `mktemp` file, which has
none, so glow passed the source through untouched and `less` faithfully
displayed `# heading`, `**bold**` and raw table pipes.

Fix: `mktemp --suffix=.md`.

`tools` was never affected, because `terminal-help.md` is a real `.md`
file — which is also why the bug only ever surfaced on the surface
someone had actually clicked.

## How it was found, and three wrong answers on the way

The reporter's hypothesis was `less`, which was reasonable and wrong.
The decisive move was to stop reasoning about it and **capture what glow
handed the pager**, by pointing `$PAGER` at a script that does
`cat > /tmp/pagerin`. That isolates glow's output from anything the
pager does with it — and the captured bytes were already unstyled, which
exonerated `less` immediately.

Getting a faithful reproduction mattered as much. The bug does not
reproduce from an interactive shell, and it does not reproduce under
`script` alone — it needs a **real terminal that answers the OSC 11
background query**, spawned from the **systemd user manager
environment** (`TERM=linux`, `PAGER=less`). The harness that finally
worked was:

```sh
env -i HOME=… PATH=… WAYLAND_DISPLAY=… TERM=linux \
  alacritty -e <a copy of guide with $PAGER pointed at the tee script>
```

Three hypotheses were tested and discarded first, each of which looked
convincing:

1. **`less` needs `-R`.** No — less 692 passes SGR sequences through
   without it. Confirmed by diffing `-R` against no `-R` under a pty:
   byte-identical.
2. **glow's `auto` style is guessing wrong.** Plausible — `auto` really
   does query the terminal and really does fall back badly when nobody
   answers — but pinning `--style dark` changed nothing.
3. **`~/.config/glow/glow.yml` overrides the CLI flags.** A stray
   `glow config` run had left one behind saying `style: "auto"`,
   `width: 80`, and an A/B seemed to confirm it. **It did not** — the
   two arms of that A/B also differed in file extension, which was the
   real variable. Re-measured cleanly afterwards: with the user config
   present and only the flags passed, a `.md` file renders correctly at
   width 98. **The flags win.** The comment that had already been
   written claiming otherwise was corrected before commit.

The clean experiment that ended it: same bytes, two filenames.

```
tmp.ZZZ111       glow-emitted-dark-H1=0
tmp.ZZZ111.md    glow-emitted-dark-H1=1     # md5sum identical
```

## What shipped

A shared `flake.lib.mkMarkdownViewer` (`flake-modules/markdown-viewer.nix`)
producing a `md-view <file.md>` helper, consumed by both `guide` and
`tools` so the two pages can't drift. Beyond the extension rule it pins
the things that were *not* the bug but are worth not leaving to chance:

- `--style dark` — no OSC 11 round trip; every terminal here is dark.
- `--width` measured from `stty size`, capped at 100 — glow's 80-column
  fallback mangles the wider tables.
- `--config /dev/null` — defence in depth, so a future `glow config` run
  can't change settings we don't pass explicitly. Explicitly documented
  as *not* the bug.
- `PAGER` pinned to a store-path `less` with `LESS="--RAW-CONTROL-CHARS
  --mouse --quit-if-one-screen"`. `--mouse` is the one users will
  notice: the wheel scrolls the guide.

`tools` changes behaviour slightly as a result — it now pages and uses
the same pinned width instead of scrolling 200 lines past you.

## Verified

- Full `guide`, run from a real alacritty spawned with the notification's
  environment: glow emits the dark-style heading block, and the bytes
  `less` draws contain it too, with mouse tracking enabled
  (`ESC[?1000h ESC[?1002h ESC[?1006h`).
- `tools` likewise (136 KB of styled output).
- Piped/redirected use still emits plain source, so `guide > page.md`
  and `tools | grep` keep working.
- All 8 buildable HM configs build; `nix flake check` passes.

## Lesson

"It renders in my terminal" is not the same claim as "it renders when
launched the way users launch it". The three surfaces here — interactive
shell, launcher, notification — differ in `TERM`, in `PAGER`, in whether
anything answers a terminal query, and in whether the document even has
a name glow will look at. Only the last one mattered, and no amount of
reasoning found it; capturing the bytes at the boundary did.

---

# Phase 6 — the last two rendering bugs, and `md-view`

Phase 5's `.md`-suffix fix made tables render, which exposed the next
layer.

## Headings kept their `#` markers

Not a bug — glamour's built-in themes do that on purpose. Measured
across the ones that have colour:

| Style | H1 | H2 / H3 |
| --- | --- | --- |
| dark, light | no `#` | `## `, `### ` kept |
| dracula, tokyo-night | `# ` kept | `## `, `### ` kept |
| pink | no marker | `▌`, `┃` bars |

Only `pink` replaces the markers, and its palette doesn't belong here.
On a page written for people who don't know what Markdown *is*, a
leftover `##` reads as broken output.

So the viewer now ships its own glamour style, authored in Nix and
serialised with `builtins.toJSON`, using this desktop's Nord-ish palette
(the one waybar, fuzzel, mako and alacritty already use): H1 as a
coloured banner, H2 with a `▌` bar in cyan, H3 green, H4-H6 purple/grey,
none of them carrying `#`.

Worth knowing for anyone editing it: **a glamour style file is used
whole — it is not merged over a built-in.** Every element that should be
styled has to appear, or it silently renders unstyled. That's why the
file is a complete document rather than a three-line heading patch.

## glow prefers stdin over its file argument

Then, making `md-view` usable on arbitrary files, a second one:

```
md-view < notes.md     -> rendered nothing
cat notes.md | md-view -> rendered nothing
md-view notes.md       -> fine
```

Traced it: the temp file was correct (`wc -c` said 111 bytes) and glow
was invoked with the right path, yet emitted two newlines. **glow reads
the document from stdin in preference to its file argument whenever
stdin isn't a terminal** — and we had already drained stdin into that
temp file, so glow was handed an empty document.

Fix is one line, and it repairs three things at once:

```sh
if [ -r /dev/tty ]; then exec </dev/tty; fi
```

glow then uses the file argument; `stty size` can measure the terminal
again (it reports nothing when stdin is a redirected file, so width was
silently falling back to 100); and the pager keeps a live terminal for
keystrokes.

## `md-view` is now a real command

It was previously reachable only by store path from `guide` and `tools`.
It is now in `home.packages` (via zsh.nix, so everywhere), because the
pinned behaviour is useful for any Markdown, not just ours:

```sh
md-view README.md
md-view NOTES              # no .md extension — normalised for you
md-view notes.markdown
curl -s …/README.md | md-view
md-view x.md | head        # piped: emits plain source, composes
```

The extension normalisation is the part that makes it strictly better
than bare `glow`: glow renders Markdown only for files *named* `.md`,
so `glow README` prints source. `md-view` copies to a `.md` temp first.

Verified: all four input forms (path, non-`.md` path, `<` redirect,
pipe) produce byte-identical rendered output, and zero literal `#`
heading lines.

## Verified (phase 6)

- Full `guide` from a real alacritty in the notification's environment:
  993 KB of rendered output, **zero** literal `#` heading lines, headings
  rendering as ` 🧭 What this machine can do` / `▌ ⌨️ Desktop shortcuts`
  / `Apps & tools`.
- All 8 buildable HM configs build; `nix flake check` passes.

---

# Phase 7 — `md-view` on native Windows

The Linux fix left `flake-modules/windows/profile.ps1` still calling
bare `glow $doc`. That path was less broken than Linux's had been —
`terminal-help.md` is a real `.md` file, so the extension bug didn't
apply — but it still inherited glow's style guess (leftover `##` on
headings), its 80-column fallback (mangled tables), and it didn't page.

## One definition, two platforms

The glamour style is now published as `flake.lib.markdownStyle`
(`flake-modules/markdown-viewer.nix`) and consumed twice:

- Linux: `pkgs.writeText` → `--style <store path>`, inside `md-view`.
- Windows: `pkgs.formats.json` → shipped in the `windows-dotfiles`
  bundle, deployed by `hm_win` to `~/.config/nixwin/md-view-style.json`,
  and pointed at by a PowerShell `md-view` function.

An empty `md-view-glow.yml` ships alongside it, playing the role
`/dev/null` plays on Linux (Windows has no usable equivalent), so a
stray `glow config` run can't change settings we don't pass explicitly.

`tools` on Windows is now a two-line wrapper over `md-view`, exactly as
on Linux.

## The pager, and a dependency that wasn't needed

glow's `--pager` shells out to `$env:PAGER` and Windows ships no usable
pager. The first attempt added `less` to the Scoop package list. That
was wrong and was reverted on review: **Git for Windows already bundles
GNU `less.exe`** under `usr\bin`, and `Git.Git` is already a hard
dependency in `wingetCli`. Zero new dependencies.

Lookup order: `less` on PATH → `usr\bin\less.exe` under the Git install
(located from `git`'s own path first, then Program Files / LOCALAPPDATA)
→ unpaged output.

Three things that look like pagers and are **not** substitutes, checked
rather than assumed, so nobody "simplifies" this later:

| Candidate | Why not |
| --- | --- |
| PowerShell `more` | a function — `$input \| Out-Host -Paging`, PowerShell's own pager, no ANSI passthrough |
| `more.com` | DOS-era; no raw-control-chars, no backward scroll |
| `uutils-more` | checked `--help`: no `-R` equivalent, would print escapes literally |

And for the record: **PowerShell has no `less` alias on any platform.**
Verified empirically (`Get-Alias` matching `less|more|pager` returns
nothing) and against the docs.

## Verified under real pwsh

The function was exercised — not just parsed — with `HOME` pointed at a
staged deploy tree, and produces output identical to Linux: no `#`
markers, `▌` bar on H2, box-drawn tables. All six paths pass: `.md`
file, non-`.md` file (normalised to a `.md` temp), piped input, `tools`,
missing file (clean error), no args (usage). Zero stray temp files after
repeated runs.

Not verified on an actual Windows machine — no access from here. The
platform-specific risk is confined to the `less.exe` discovery, which
degrades to unpaged rendering rather than failing.

---

# Phase 8 — mermaid diagrams in `md-view`

## Why not the obvious tool

`mermaid-cli` (mmdc) is in nixpkgs and is the standard answer. Measured:
**2.1 GiB closure**, because it bundles Chromium. And it only emits
PNG/SVG — which alacritty cannot display: mainline alacritty (0.17 here)
implements no image protocol, neither sixel nor kitty graphics. The
image would then need `chafa` (another 157 MiB) to become Unicode-block
art, illegible for a diagram with text in it. ~2.3 GiB per host to
render diagrams badly.

`mermaid-ascii` emits plain text, which is what a pager can actually
show. Single Go binary, 51 MiB, MIT, actively maintained (1.4.0,
Jul 2026). Not in nixpkgs → `overlays/mermaid-ascii.nix`.

## The finding that shaped the design

mermaid-ascii covers a subset, and fails in **two different ways**:

| Input | Behaviour |
| --- | --- |
| `sequenceDiagram` | renders correctly (incl. notes, alt/loop) |
| `graph`/`flowchart` with `[square]` nodes | renders correctly (incl. edge labels, subgraphs) |
| `classDiagram`, `stateDiagram`, `erDiagram`, `pie`, `gantt`, `mindmap` | **exit 1** — easy to detect |
| `(round)`, `((circle))`, `{diamond}`, `>flag]`, `[[sub]]`, `[(db)]` | **exit 0, wrong output** |

That last row is the dangerous one. `A[Boot] --> B{On AC power?}` yields
a box literally labelled `B{On AC power?}` *and* a phantom node `B` —
a diagram that is confidently, silently wrong. Decision diamonds are
everywhere in real READMEs, and `md-view` is now a general-purpose tool
pointed at arbitrary files.

So rendering is **conservative**: the first meaningful line decides the
diagram type; for flowcharts, the block is scanned for unsupported shape
tokens and left as source if any are found; anything that exits non-zero
or produces nothing is left as source. Net effect: never worse than
before (glow already showed these as source), better where it is safe.

Implemented in pure bash inside md-view — no awk/sed/python — so the
closure grows only by mermaid-ascii itself. md-view's total closure is
90 MiB against a 16.7 GiB home-manager path.

## Windows

Go cross-compiles, so `pkgs.mermaid-ascii.overrideAttrs` with
`env.GOOS = "windows"` produces a 13.8 MiB static `.exe` with no Windows
toolchain involved. It ships in the `windows-dotfiles` bundle and
deploys to `~/.config/nixwin/bin/`, and the PowerShell `md-view`
implements the same conservative rules. Verified under pwsh against the
same test document: output identical to Linux, including both fallbacks.

Note the `env` detail: buildGoModule keeps GOOS/GOARCH/CGO_ENABLED in
`env`, and passing them as plain derivation arguments is a "cannot
contain any attributes passed to derivation" eval error.

This is the **first binary** hm_win ships (everything else is text
config), hence the explicit `chmod 0755` after deploy — `deploy()`
installs 0644, which Windows ignores but WSL does not.

## A wiring bug this exposed

`perSystem = { pkgs, ... }` gets flake-parts' **bare** nixpkgs, without
this repo's overlays, so `pkgs.mermaid-ascii` was missing. Fixed by
building the bundle from `config.flake.lib.mkPkgs system` — the same
factory every host bridge uses. Worth knowing generally: anything in
`perSystem` that needs an overlay must go through `mkPkgs`.

## Verified

- Both supported diagram types render; both unsupported cases fall back
  to source. Checked on Linux through a real pty and on Windows under
  pwsh, with byte-identical results.
- Piped output still emits plain source; no stray temp files.
- All 8 buildable HM configs build; `nix flake check` passes.
