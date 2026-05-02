// idled — small idle-action daemon.
//
// Why this exists
// ---------------
// Smithay's `ext_idle_notifier_v1` implementation is broken (Smithay #1892,
// open as of 2026-04): on niri sessions Resumed events are never sent, so any
// daemon that relies on the wayland idle protocol — swayidle, stasis,
// hypridle, cosmic-idle, wayidle — sees the session as permanently idle once
// it idles once, and locks the screen at random while the user is typing.
//
// idled bypasses the wayland layer entirely: it reads /dev/input/event*
// directly via evdev. Activity detected at the kernel input layer cannot be
// missed by a wayland compositor bug.
//
// Design
// ------
// One async task per input device (keyboard / pointer / touchpad). Every
// event nudges a shared `last_input` Instant. A 1Hz tick task evaluates each
// configured stage (lock / dpms / suspend) and fires its `command` if
// `now - last_input >= timeout` and the stage hasn't already fired since the
// last input. On fresh input, fired stages run their `resume_command` (used
// by DPMS to wake monitors after a tap).
//
// A separate task watches /dev/input/ via inotify so USB keyboards/mice
// hot-plugged after start are still tracked.
//
// Logind integration:
//   - PrepareForSleep(false) → treat as fresh input (reset last_input + fired).
//   - BlockInhibited containing "idle" → defer all stages while held.
//
// Permissions
// -----------
// /dev/input/event* is root:input mode 0660. The user must be in `input`
// group, or this daemon must run as root. Running as the user is preferred
// because `command` strings inherit WAYLAND_DISPLAY / XDG_RUNTIME_DIR from
// the user session and can call `quickshell ipc`, `niri msg`, etc., directly.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use clap::Parser;
use serde::Deserialize;
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};

mod dbus;
mod input;
mod power;
mod screensaver;

#[derive(Parser, Debug)]
#[command(version, about = "Kernel-input idle manager")]
struct Args {
    /// Path to the TOML config. Defaults to $XDG_CONFIG_HOME/idled/config.toml.
    #[arg(short, long)]
    config: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct Config {
    #[serde(default)]
    general: General,
    #[serde(default)]
    stages: Vec<Stage>,
    /// Optional battery watcher: switch power-profiles-daemon profile when
    /// the battery descends past a threshold while discharging. Absent
    /// section disables the watcher entirely.
    #[serde(default)]
    battery: Option<power::BatteryConfig>,
}

#[derive(Debug, Deserialize)]
struct General {
    /// Tick interval in milliseconds. Default 1000.
    #[serde(default = "default_tick_ms")]
    tick_ms: u64,
    /// Honour logind idle inhibitors. Default true.
    #[serde(default = "default_true")]
    respect_idle_inhibitors: bool,
    /// Shell command to run *before* the system suspends/hibernates so the
    /// lockscreen is up before the screen blanks. Absent = don't lock on
    /// sleep. Paired with a logind delay-inhibitor so suspend waits for
    /// this command (plus `lock_settle_ms`) to complete before proceeding.
    #[serde(default)]
    lock_before_sleep: Option<String>,
    /// Milliseconds to wait after spawning lock_before_sleep before
    /// releasing the suspend inhibitor. Tuned to give the wayland
    /// compositor time to paint the lockscreen surface. Default 300.
    #[serde(default = "default_lock_settle_ms")]
    lock_settle_ms: u64,
}

impl Default for General {
    fn default() -> Self {
        Self {
            tick_ms: default_tick_ms(),
            respect_idle_inhibitors: true,
            lock_before_sleep: None,
            lock_settle_ms: default_lock_settle_ms(),
        }
    }
}

fn default_tick_ms() -> u64 {
    1000
}
fn default_true() -> bool {
    true
}
fn default_lock_settle_ms() -> u64 {
    300
}

#[derive(Debug, Deserialize, Clone)]
struct Stage {
    /// Stage name for logging (e.g. "lock", "dpms", "suspend").
    name: String,
    /// Seconds of inactivity before this stage fires.
    timeout: u64,
    /// Shell command to run when the stage fires.
    command: String,
    /// Optional shell command to run on the next input event after the stage
    /// has fired. Used to wake monitors after DPMS off.
    #[serde(default)]
    resume_command: Option<String>,
}

#[derive(Debug, Default)]
pub struct State {
    pub last_input: Option<Instant>,
    /// Per-stage: has it fired since the last input?
    pub fired: HashMap<String, bool>,
}

impl State {
    fn touch(&mut self, now: Instant) {
        self.last_input = Some(now);
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args = Args::parse();
    let cfg_path = args.config.unwrap_or_else(default_config_path);
    let cfg_text = std::fs::read_to_string(&cfg_path)
        .with_context(|| format!("reading config {}", cfg_path.display()))?;
    let cfg: Config = toml::from_str(&cfg_text).context("parsing config")?;

    if cfg.stages.is_empty() {
        warn!("no stages configured; idled will only track input and do nothing");
    } else {
        info!(
            stages = cfg.stages.len(),
            "starting idled with {} stage(s)",
            cfg.stages.len()
        );
        for s in &cfg.stages {
            info!(stage = %s.name, timeout_s = s.timeout, "configured");
        }
    }

    let state = Arc::new(Mutex::new(State::default()));
    // Mark "active now" on startup so we don't immediately fire stages whose
    // timeout has technically elapsed (e.g. timeout=300 and the daemon was
    // just restarted — the user is sitting at the screen, not idle for 300s).
    {
        let mut s = state.lock().await;
        s.touch(Instant::now());
    }

    // Channel: input tasks send () on every event; tick task consumes them.
    let (input_tx, mut input_rx) = tokio::sync::mpsc::unbounded_channel::<()>();

    // Spawn input watcher. It opens existing devices and watches for new ones.
    tokio::spawn(async move {
        if let Err(e) = input::watch_all(input_tx).await {
            error!(error = %e, "input watcher exited");
        }
    });

    // Spawn dbus task: PrepareForSleep + BlockInhibited + (optional) lock-on-sleep.
    //
    // Two independent inhibitor sources, OR'd in the tick loop:
    //   * `logind_inhibitor`     — set by dbus::run when logind's
    //     BlockInhibited contains "idle" (i.e. someone holds a
    //     `systemd-inhibit --what=idle` lease).
    //   * `screensaver_inhibitor` — set by screensaver::run when at least
    //     one client holds a cookie via org.freedesktop.ScreenSaver.Inhibit
    //     (Chrome on fullscreen video, mpv, wayland-pipewire-idle-inhibit
    //     bridge with --idle-inhibitor d-bus, etc.).
    // Each source owns its own flag so neither overwrites the other on
    // an unrelated state change.
    let dbus_state = state.clone();
    let logind_inhibitor = Arc::new(Mutex::new(false));
    let screensaver_inhibitor = Arc::new(Mutex::new(false));
    let dbus_inhibitor = logind_inhibitor.clone();
    let lock_cfg = cfg
        .general
        .lock_before_sleep
        .clone()
        .map(|cmd| dbus::LockOnSleep {
            command: cmd,
            settle_ms: cfg.general.lock_settle_ms,
        });
    if let Some(ref l) = lock_cfg {
        info!(
            settle_ms = l.settle_ms,
            "lock-before-sleep enabled (delay inhibitor + lock command)"
        );
    }
    tokio::spawn(async move {
        if let Err(e) = dbus::run(dbus_state, dbus_inhibitor, lock_cfg).await {
            error!(error = %e, "dbus task exited");
        }
    });

    // Spawn ScreenSaver D-Bus server (session bus). Catches inhibits from
    // Chrome (fullscreen video), mpv, and the `wayland-pipewire-idle-
    // inhibit` bridge run with `--idle-inhibitor d-bus`. Owns the
    // `screensaver_inhibitor` flag exclusively; idled OR's both flags in
    // the tick loop. If another screensaver service is already running on
    // the session bus, this task fails and exits cleanly; logind path stays.
    let ss_inhibitor = screensaver_inhibitor.clone();
    tokio::spawn(async move {
        if let Err(e) = screensaver::run(ss_inhibitor).await {
            warn!(error = %e, "screensaver task exited");
        }
    });

    // Spawn battery watcher if configured. Optional — hosts without a
    // battery (or without PPD) simply omit the [battery] section.
    if let Some(bcfg) = cfg.battery.clone() {
        info!(
            threshold = bcfg.power_saver_percent,
            "starting battery / power-profiles watcher"
        );
        tokio::spawn(async move {
            if let Err(e) = power::run(bcfg).await {
                error!(error = %e, "battery watcher exited");
            }
        });
    } else {
        debug!("no [battery] section in config; battery watcher disabled");
    }

    // Drain input_rx alongside the tick: every input bumps last_input and
    // reruns resume actions for any stage that had fired.
    let stages = cfg.stages.clone();
    let respect_inhib = cfg.general.respect_idle_inhibitors;
    let tick = Duration::from_millis(cfg.general.tick_ms);

    let mut interval = tokio::time::interval(tick);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            // Drain ALL pending input events between ticks; we don't need
            // one tick per event, only one touch per batch.
            biased;
            n = recv_batch(&mut input_rx) => {
                if n == 0 {
                    // channel closed
                    warn!("input channel closed; exiting");
                    return Ok(());
                }
                let now = Instant::now();
                let mut s = state.lock().await;
                s.touch(now);
                // For any stage that had fired, fire its resume_command and
                // clear its fired flag so it can fire again later.
                let to_resume: Vec<Stage> = stages
                    .iter()
                    .filter(|st| s.fired.get(&st.name).copied().unwrap_or(false))
                    .cloned()
                    .collect();
                for st in &to_resume {
                    s.fired.insert(st.name.clone(), false);
                }
                drop(s);
                for st in to_resume {
                    if let Some(cmd) = st.resume_command {
                        debug!(stage = %st.name, "input — running resume_command");
                        spawn_command(&cmd, &format!("{}-resume", st.name));
                    } else {
                        debug!(stage = %st.name, "input — clearing fired flag");
                    }
                }
            }
            _ = interval.tick() => {
                // Inhibited if EITHER source has a hold. Locked separately
                // so a slow ScreenSaver Inhibit call can't block reading
                // the logind flag and vice-versa.
                let inhibited = respect_inhib && (
                    *logind_inhibitor.lock().await
                    || *screensaver_inhibitor.lock().await
                );
                if inhibited {
                    // Don't fire anything while inhibited. Don't clear fired
                    // either — that's an input's job.
                    continue;
                }
                let now = Instant::now();
                let mut s = state.lock().await;
                let last = match s.last_input {
                    Some(t) => t,
                    None => continue,
                };
                let elapsed = now.saturating_duration_since(last);
                let mut to_fire: Vec<Stage> = Vec::new();
                for st in &stages {
                    if s.fired.get(&st.name).copied().unwrap_or(false) {
                        continue;
                    }
                    if elapsed >= Duration::from_secs(st.timeout) {
                        s.fired.insert(st.name.clone(), true);
                        to_fire.push(st.clone());
                    }
                }
                drop(s);
                for st in to_fire {
                    info!(stage = %st.name, elapsed_s = elapsed.as_secs(), "firing");
                    spawn_command(&st.command, &st.name);
                }
            }
        }
    }
}

async fn recv_batch(rx: &mut tokio::sync::mpsc::UnboundedReceiver<()>) -> usize {
    // Block on first event, then drain all queued ones non-blockingly.
    if rx.recv().await.is_none() {
        return 0;
    }
    let mut n = 1usize;
    while rx.try_recv().is_ok() {
        n += 1;
    }
    n
}

fn spawn_command(cmd: &str, label: &str) {
    let cmd = cmd.to_string();
    let label = label.to_string();
    tokio::spawn(async move {
        let mut child = match tokio::process::Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .spawn()
        {
            Ok(c) => {
                // Successful spawn — clear the consecutive-ENOENT counter so a
                // single transient ENOENT (e.g. early-boot race against
                // /run/current-system/sw/bin) doesn't accumulate toward the
                // fail-fast threshold below.
                ENOENT_STREAK.store(0, Ordering::Relaxed);
                c
            }
            Err(e) => {
                error!(action = %label, command = %cmd, error = %e, "failed to spawn");
                // Fail loudly on persistent ENOENT. Background:
                //   - idled spawns every stage command via `sh -c "<cmd>"`.
                //   - PATH inside the systemd-user unit is whatever the
                //     unit's Environment= line provides; on NixOS the
                //     executor default is just systemd's own bin dir.
                //   - If the unit Environment is missing /run/current-system/sw/bin
                //     (regression), `sh` cannot find quickshell / niri / systemctl
                //     and every stage fires a silent ENOENT. The daemon keeps
                //     running, the laptop never suspends, and nothing in
                //     `nixos-rebuild switch` complains.
                // Threshold is intentionally >1: a one-shot race during early
                // graphical-session startup is plausible. Three consecutive
                // ENOENTs across distinct stage firings is unambiguously a
                // config error — exit non-zero so systemd marks the unit
                // failed and the next `nixos-rebuild switch` surfaces it.
                if e.kind() == std::io::ErrorKind::NotFound {
                    let n = ENOENT_STREAK.fetch_add(1, Ordering::Relaxed) + 1;
                    if n >= ENOENT_FAIL_THRESHOLD {
                        error!(
                            consecutive = n,
                            threshold = ENOENT_FAIL_THRESHOLD,
                            "exiting: {} consecutive spawn ENOENTs — PATH or store paths likely broken in unit Environment",
                            n
                        );
                        // Give the tracing layer a moment to flush before exit.
                        std::process::exit(1);
                    }
                } else {
                    // Non-ENOENT errors (EAGAIN, EMFILE, etc.) are unrelated
                    // to PATH; reset the streak so we don't conflate them.
                    ENOENT_STREAK.store(0, Ordering::Relaxed);
                }
                return;
            }
        };
        match child.wait().await {
            Ok(s) if s.success() => debug!(action = %label, "ok"),
            Ok(s) => warn!(action = %label, exit = ?s.code(), "non-zero exit"),
            Err(e) => error!(action = %label, error = %e, "wait failed"),
        }
    });
}

// Consecutive ENOENT spawns. See spawn_command for rationale.
static ENOENT_STREAK: AtomicUsize = AtomicUsize::new(0);
const ENOENT_FAIL_THRESHOLD: usize = 3;

fn default_config_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let mut h = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
            h.push(".config");
            h
        });
    let mut p: PathBuf = base;
    p.push("idled/config.toml");
    p
}
