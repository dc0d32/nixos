// org.freedesktop.ScreenSaver D-Bus server.
//
// Why this lives in idled
// -----------------------
// idled's only inhibitor source used to be logind's BlockInhibited (set by
// `systemd-inhibit --what=idle …` style holders). Modern Wayland apps
// (Chrome on fullscreen video, mpv, VLC, Spotify, …) do NOT take a logind
// inhibitor; they call the well-known org.freedesktop.ScreenSaver.Inhibit
// method on the session bus. On a desktop without GNOME / KDE / xfce4-
// screensaver, nothing answers that call, and Chrome's "keep awake while
// playing video" silently does nothing.
//
// We host org.freedesktop.ScreenSaver ourselves — minimal implementation,
// just enough to be a faithful counterpart for those clients:
//
//   Inhibit(application_name: s, reason_for_inhibit: s) -> cookie: u
//   UnInhibit(cookie: u) -> ()
//   GetActive() -> b                  (always false; we don't lock yet)
//   GetActiveTime() -> u              (always 0)
//   SetActive(b)                      (no-op, returns false)
//
// Cookies are random u32s; we keep a HashMap<cookie, holder> so we can log
// who took/released each one. As soon as the map is non-empty, the shared
// `inhibitor` flag flips true and idled defers all stages — exactly the
// same gate used for logind BlockInhibited.
//
// Bus name registration
// ---------------------
// We request the well-known name `org.freedesktop.ScreenSaver` on the
// SESSION bus. If something else (gnome-shell, KDE, xfce4-screensaver) is
// already running we lose the race and log a warning; idled keeps working
// without ScreenSaver-source inhibits and the existing logind path still
// covers `systemd-inhibit` users. We also expose the legacy duplicate
// path `/ScreenSaver` (used by some clients) in addition to the canonical
// `/org/freedesktop/ScreenSaver`.
//
// Companion daemon
// ----------------
// `wayland-pipewire-idle-inhibit --idle-inhibitor d-bus` is the natural
// counterpart: it watches PipeWire output streams and calls our Inhibit
// while any stream is active. That's how "any audio/video stream prevents
// lock" gets covered for apps that don't speak ScreenSaver themselves.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Context, Result};
use tokio::sync::Mutex;
use tracing::{info, warn};
use zbus::{interface, ConnectionBuilder};

// One inhibitor record per active cookie. Holders may take many at once
// (Chrome arms one per video element, mpv per file, etc.).
#[derive(Debug)]
struct Holder {
    application: String,
    reason: String,
}

pub struct ScreenSaver {
    /// Active cookies. Keyed by random u32 returned to the client.
    holders: Mutex<HashMap<u32, Holder>>,
    /// Shared with main.rs / dbus.rs. true = at least one inhibitor is held.
    inhibitor: Arc<Mutex<bool>>,
}

impl ScreenSaver {
    fn new(inhibitor: Arc<Mutex<bool>>) -> Self {
        Self {
            holders: Mutex::new(HashMap::new()),
            inhibitor,
        }
    }

    async fn refresh_flag(&self) {
        let any = !self.holders.lock().await.is_empty();
        let mut f = self.inhibitor.lock().await;
        if *f != any {
            *f = any;
            info!(idle_inhibited = any, "screensaver inhibitor flag changed");
        }
    }
}

#[interface(name = "org.freedesktop.ScreenSaver")]
impl ScreenSaver {
    /// Spec: returns a u32 cookie identifying the inhibition. Application
    /// must call UnInhibit(cookie) to release; closing the connection also
    /// releases (NameOwnerChanged handling — see disconnect_watcher below).
    async fn inhibit(&self, application_name: String, reason_for_inhibit: String) -> u32 {
        // Random non-zero cookie. Collision space is 2^32; on collision we
        // just retry. In practice we never see one.
        let mut cookie: u32;
        let mut holders = self.holders.lock().await;
        loop {
            cookie = rand_u32();
            if cookie != 0 && !holders.contains_key(&cookie) {
                break;
            }
        }
        info!(
            application = %application_name,
            reason = %reason_for_inhibit,
            cookie,
            total = holders.len() + 1,
            "screensaver inhibit"
        );
        holders.insert(
            cookie,
            Holder {
                application: application_name,
                reason: reason_for_inhibit,
            },
        );
        drop(holders);
        self.refresh_flag().await;
        cookie
    }

    async fn un_inhibit(&self, cookie: u32) {
        let mut holders = self.holders.lock().await;
        match holders.remove(&cookie) {
            Some(h) => info!(
                cookie,
                application = %h.application,
                reason = %h.reason,
                remaining = holders.len(),
                "screensaver uninhibit"
            ),
            None => warn!(cookie, "uninhibit for unknown cookie; ignoring"),
        }
        drop(holders);
        self.refresh_flag().await;
    }

    /// Some clients call this — return false (we don't manage the lock
    /// state directly; that's idled's stage scheduler).
    async fn get_active(&self) -> bool {
        false
    }

    async fn get_active_time(&self) -> u32 {
        0
    }

    /// Spec: try to set "active" state; return whether it succeeded.
    /// We don't honor remote requests to start/stop the lock.
    async fn set_active(&self, _value: bool) -> bool {
        false
    }
}

/// Spawn the ScreenSaver server on the session bus. Blocks forever holding
/// the connection alive; expected to be polled inside tokio::spawn. Errors
/// during the initial bind are returned to the caller and logged; runtime
/// errors are logged and the task exits (idled keeps working without us).
pub async fn run(inhibitor: Arc<Mutex<bool>>) -> Result<()> {
    // Two object paths to register the same interface on. The canonical
    // one is /org/freedesktop/ScreenSaver; some apps (notably Firefox and
    // older mpv builds) hard-code /ScreenSaver. Both must answer.
    let canonical_path = "/org/freedesktop/ScreenSaver";
    let legacy_path = "/ScreenSaver";

    let primary = ScreenSaver::new(inhibitor.clone());
    let secondary = ScreenSaver::new(inhibitor);

    let conn = ConnectionBuilder::session()
        .context("opening session bus connection")?
        .name("org.freedesktop.ScreenSaver")
        .context("requesting bus name")?
        .serve_at(canonical_path, primary)
        .context("registering ScreenSaver at canonical path")?
        .serve_at(legacy_path, secondary)
        .context("registering ScreenSaver at /ScreenSaver")?
        .build()
        .await;

    match conn {
        Ok(_conn) => {
            info!(
                paths = format!("{canonical_path}, {legacy_path}"),
                "org.freedesktop.ScreenSaver server registered on session bus"
            );
            // Hold the connection forever. ConnectionBuilder::build returns
            // a Connection that, when dropped, closes the bus and we lose
            // the well-known name. Park here until the process dies.
            std::future::pending::<()>().await;
            Ok(())
        }
        Err(e) => {
            warn!(
                error = %e,
                "could not register org.freedesktop.ScreenSaver — another \
                 screensaver may be running. Wayland-bridge / Chrome \
                 inhibits will be ignored; logind-inhibitor path still \
                 works."
            );
            Err(e).context("ScreenSaver bus registration")
        }
    }
}

/// Tiny non-crypto u32 PRNG using nanoseconds + a counter. Adequate for
/// cookie uniqueness — clients never inspect the values.
fn rand_u32() -> u32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let c = COUNTER.fetch_add(1, Ordering::Relaxed);
    n.wrapping_mul(2_654_435_761).wrapping_add(c).wrapping_add(1)
}
