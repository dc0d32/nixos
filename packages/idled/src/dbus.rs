// Logind dbus integration.
//
// Two signals/properties are interesting:
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

use std::sync::Arc;
use std::time::Instant;

use anyhow::Result;
use futures_util::StreamExt;
use tokio::sync::Mutex;
use tracing::{debug, info, warn};
use zbus::{proxy, Connection};

use crate::State;

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
}

pub async fn run(state: Arc<Mutex<State>>, inhibitor: Arc<Mutex<bool>>) -> Result<()> {
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

    let mut sleep_stream = mgr.receive_prepare_for_sleep().await?;
    let mut inhibit_stream = mgr.receive_block_inhibited_changed().await;

    loop {
        tokio::select! {
            Some(sig) = sleep_stream.next() => {
                match sig.args() {
                    Ok(args) => {
                        let active = args.active;
                        if !active {
                            info!("resumed from sleep — treating as fresh input");
                            let mut s = state.lock().await;
                            s.last_input = Some(Instant::now());
                            s.fired.clear();
                        } else {
                            debug!("preparing for sleep");
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
