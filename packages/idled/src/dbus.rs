// Logind dbus integration.
//
// Three responsibilities:
//
// 1. PrepareForSleep(active: bool) on org.freedesktop.login1.Manager.
//    Fires twice around suspend: with `true` just before going to sleep, and
//    with `false` immediately after resuming. On resume we treat the moment
//    as fresh activity so the screen doesn't immediately re-lock from
//    elapsed pre-suspend time.
//
// 2. BlockInhibited property on the same Manager. A space-separated list of
//    inhibition modes currently held by *anyone*; if it contains "idle"
//    we defer firing any stage. This is how `wayland-pipewire-idle-inhibit`,
//    mpv, browsers playing video, etc., ask the system not to lock.
//
// 3. Lock-on-sleep (optional, configured via [general].lock_before_sleep).
//    Holds a logind delay-inhibitor at all times when armed; on
//    PrepareForSleep(true) spawns the lock command, sleeps `settle_ms`
//    so the compositor can paint the lockscreen surface, then drops the
//    inhibitor so suspend can proceed. Re-acquires the inhibitor on
//    PrepareForSleep(false) for the next sleep cycle.
//
// Why the delay-inhibitor matters: without it, logind goes straight from
// PrepareForSleep(true) to actual suspend within milliseconds, and our
// `quickshell ipc call lock lock` may not have rendered yet. On resume the
// user would see the desktop for a frame before the lockscreen pops up.
// The `delay` mode makes logind wait up to InhibitDelayMaxSec (5s by
// default) for all delay inhibitors to release.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use futures_util::StreamExt;
use tokio::sync::Mutex;
use tracing::{debug, info, warn};
use zbus::zvariant::OwnedFd;
use zbus::{proxy, Connection};

use crate::State;

#[derive(Debug, Clone)]
pub struct LockOnSleep {
    pub command: String,
    pub settle_ms: u64,
}

#[proxy(
    interface = "org.freedesktop.login1.Manager",
    default_service = "org.freedesktop.login1",
    default_path = "/org/freedesktop/login1"
)]
trait Manager {
    #[zbus(signal)]
    fn prepare_for_sleep(&self, active: bool) -> zbus::Result<()>;

    #[zbus(property)]
    fn block_inhibited(&self) -> zbus::Result<String>;

    /// Take an inhibitor lock. Returns a UnixFD; the inhibitor is held as
    /// long as the FD is open. Closing the FD releases the lock.
    /// `what`  : space-separated subset of
    ///           {shutdown,sleep,idle,handle-power-key,handle-suspend-key,
    ///            handle-hibernate-key,handle-lid-switch}.
    /// `mode`  : "block" (refuse the action) or "delay" (defer it up to
    ///           InhibitDelayMaxSec while we run our hook).
    fn inhibit(&self, what: &str, who: &str, why: &str, mode: &str)
        -> zbus::Result<OwnedFd>;
}

/// Take a delay-inhibitor on `sleep`. Returned FD must be kept alive; drop
/// it to release the inhibitor.
async fn take_sleep_inhibitor(mgr: &ManagerProxy<'_>) -> Result<OwnedFd> {
    mgr.inhibit(
        "sleep",
        "idled",
        "lock screen before suspend",
        "delay",
    )
    .await
    .context("logind Inhibit(sleep, delay) call")
}

pub async fn run(
    state: Arc<Mutex<State>>,
    inhibitor: Arc<Mutex<bool>>,
    lock_on_sleep: Option<LockOnSleep>,
) -> Result<()> {
    let conn = Connection::system().await?;
    let mgr = ManagerProxy::new(&conn).await?;

    // Initial inhibitor state.
    match mgr.block_inhibited().await {
        Ok(s) => {
            let v = s.split(':').any(|m| m == "idle");
            *inhibitor.lock().await = v;
            info!(initial = %s, idle_inhibited = v, "logind block_inhibited");
        }
        Err(e) => warn!(error = %e, "could not read block_inhibited"),
    }

    // If lock-on-sleep is configured, take an initial delay-inhibitor so
    // the very first suspend after daemon start is also blocked until we
    // run the lock command.
    let mut sleep_lock: Option<OwnedFd> = if lock_on_sleep.is_some() {
        match take_sleep_inhibitor(&mgr).await {
            Ok(fd) => {
                debug!("acquired logind sleep delay-inhibitor");
                Some(fd)
            }
            Err(e) => {
                warn!(error = %e, "could not take initial sleep inhibitor; lock-on-sleep will race");
                None
            }
        }
    } else {
        None
    };

    let mut sleep_stream = mgr.receive_prepare_for_sleep().await?;
    let mut inhibit_stream = mgr.receive_block_inhibited_changed().await;

    loop {
        tokio::select! {
            Some(sig) = sleep_stream.next() => {
                match sig.args() {
                    Ok(args) => {
                        let active = args.active;
                        if active {
                            // Pre-sleep: lock the screen, give it a moment
                            // to paint, then drop the delay-inhibitor so
                            // logind can actually suspend.
                            if let Some(cfg) = lock_on_sleep.as_ref() {
                                info!(command = %cfg.command, "preparing for sleep — locking screen");
                                spawn_shell(&cfg.command, "lock-before-sleep");
                                tokio::time::sleep(Duration::from_millis(cfg.settle_ms)).await;
                                if sleep_lock.take().is_some() {
                                    debug!("released sleep delay-inhibitor");
                                }
                            } else {
                                debug!("preparing for sleep");
                            }
                        } else {
                            info!("resumed from sleep — treating as fresh input");
                            let mut s = state.lock().await;
                            s.last_input = Some(Instant::now());
                            s.fired.clear();
                            drop(s);
                            // Re-arm the delay-inhibitor for the next cycle.
                            if lock_on_sleep.is_some() && sleep_lock.is_none() {
                                match take_sleep_inhibitor(&mgr).await {
                                    Ok(fd) => {
                                        sleep_lock = Some(fd);
                                        debug!("re-acquired sleep delay-inhibitor");
                                    }
                                    Err(e) => warn!(error = %e, "could not re-take sleep inhibitor"),
                                }
                            }
                        }
                    }
                    Err(e) => warn!(error = %e, "PrepareForSleep args parse"),
                }
            }
            Some(change) = inhibit_stream.next() => {
                match change.get().await {
                    Ok(s) => {
                        let v = s.split(':').any(|m| m == "idle");
                        *inhibitor.lock().await = v;
                        debug!(value = %s, idle_inhibited = v, "block_inhibited changed");
                    }
                    Err(e) => warn!(error = %e, "block_inhibited get"),
                }
            }
            else => break,
        }
    }
    Ok(())
}

fn spawn_shell(cmd: &str, label: &str) {
    let cmd = cmd.to_string();
    let label = label.to_string();
    tokio::spawn(async move {
        match tokio::process::Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .spawn()
        {
            Ok(mut child) => match child.wait().await {
                Ok(s) if s.success() => debug!(action = %label, "ok"),
                Ok(s) => warn!(action = %label, exit = ?s.code(), "non-zero exit"),
                Err(e) => warn!(action = %label, error = %e, "wait failed"),
            },
            Err(e) => warn!(action = %label, command = %cmd, error = %e, "failed to spawn"),
        }
    });
}
