// UPower + power-profiles-daemon integration.
//
// Why this lives in idled
// -----------------------
// We already run a long-lived user daemon with zbus, tokio, and a logind
// connection. Spawning a second daemon just to flip a power profile when
// the battery dips below N% would be silly. The watcher here is small,
// optional (gated by config), and reuses idled's runtime.
//
// What it does
// ------------
// 1. Subscribes to PropertiesChanged on the UPower DisplayDevice (the
//    aggregate battery), watching `Percentage` and `State`.
// 2. When discharging and percentage falls to/below `power_saver_percent`,
//    snapshots the current PPD ActiveProfile and sets it to "power-saver".
// 3. When the battery climbs back above (threshold + hysteresis) OR the
//    state transitions to Charging / FullyCharged, restores the snapshotted
//    profile (if we still have one).
//
// The watcher never overrides the user manually picking a profile *while
// in saver mode*: it only restores if the active profile at restore time
// is still "power-saver". If the user already moved to e.g. "balanced",
// we leave it alone and clear our snapshot.
//
// dbus surfaces
// -------------
//   org.freedesktop.UPower / /org/freedesktop/UPower/devices/DisplayDevice
//     interface org.freedesktop.UPower.Device
//       Percentage : d
//       State      : u   (1=Charging 2=Discharging 3=Empty 4=FullyCharged
//                        5=PendingCharge 6=PendingDischarge)
//
//   net.hadess.PowerProfiles / /net/hadess/PowerProfiles
//     interface net.hadess.PowerProfiles
//       ActiveProfile : s   ("power-saver" | "balanced" | "performance")
//
// PPD changed its bus name to org.freedesktop.UPower.PowerProfiles in
// newer versions. We try the new name first and fall back to net.hadess.

use std::sync::Arc;

use anyhow::{Context, Result};
use futures_util::StreamExt;
use tokio::sync::Mutex;
use tracing::{debug, info, warn};
use zbus::{proxy, Connection};

#[derive(Debug, Clone, serde::Deserialize)]
pub struct BatteryConfig {
    /// Percent at or below which we switch to power-saver while discharging.
    pub power_saver_percent: u32,
    /// Hysteresis band (percent) to add to the threshold before restoring.
    /// Default 5: descend at <=40, ascend at >=45.
    #[serde(default = "default_hysteresis")]
    pub hysteresis: u32,
}

fn default_hysteresis() -> u32 {
    5
}

#[proxy(
    interface = "org.freedesktop.UPower.Device",
    default_service = "org.freedesktop.UPower",
    default_path = "/org/freedesktop/UPower/devices/DisplayDevice"
)]
trait UPowerDevice {
    #[zbus(property)]
    fn percentage(&self) -> zbus::Result<f64>;
    #[zbus(property)]
    fn state(&self) -> zbus::Result<u32>;
}

// New PPD bus name (>= ~0.20).
#[proxy(
    interface = "org.freedesktop.UPower.PowerProfiles",
    default_service = "org.freedesktop.UPower.PowerProfiles",
    default_path = "/org/freedesktop/UPower/PowerProfiles"
)]
trait PowerProfilesNew {
    #[zbus(property)]
    fn active_profile(&self) -> zbus::Result<String>;
    #[zbus(property)]
    fn set_active_profile(&self, profile: &str) -> zbus::Result<()>;
}

// Legacy net.hadess.PowerProfiles name still in service on many systems.
#[proxy(
    interface = "net.hadess.PowerProfiles",
    default_service = "net.hadess.PowerProfiles",
    default_path = "/net/hadess/PowerProfiles"
)]
trait PowerProfilesOld {
    #[zbus(property)]
    fn active_profile(&self) -> zbus::Result<String>;
    #[zbus(property)]
    fn set_active_profile(&self, profile: &str) -> zbus::Result<()>;
}

/// Thin enum so the rest of the file doesn't care which bus name PPD uses.
enum Ppd<'a> {
    New(PowerProfilesNewProxy<'a>),
    Old(PowerProfilesOldProxy<'a>),
}

impl<'a> Ppd<'a> {
    async fn connect(conn: &Connection) -> Result<Ppd<'static>> {
        // Try new name first; fall back to legacy.
        match PowerProfilesNewProxy::new(conn).await {
            Ok(p) => match p.active_profile().await {
                Ok(_) => return Ok(Ppd::New(p.into())),
                Err(e) => debug!(error = %e, "new PPD bus present but unreadable"),
            },
            Err(e) => debug!(error = %e, "new PPD bus name unavailable"),
        }
        let p = PowerProfilesOldProxy::new(conn)
            .await
            .context("connecting legacy PPD proxy")?;
        // Probe — if PPD isn't running we want a clean error here.
        let _ = p
            .active_profile()
            .await
            .context("reading PPD ActiveProfile (is power-profiles-daemon running?)")?;
        Ok(Ppd::Old(p.into()))
    }

    async fn get(&self) -> zbus::Result<String> {
        match self {
            Ppd::New(p) => p.active_profile().await,
            Ppd::Old(p) => p.active_profile().await,
        }
    }

    async fn set(&self, profile: &str) -> zbus::Result<()> {
        match self {
            Ppd::New(p) => p.set_active_profile(profile).await,
            Ppd::Old(p) => p.set_active_profile(profile).await,
        }
    }
}

// State machine bookkeeping.
#[derive(Default)]
struct Saver {
    /// Profile that was active when we descended past the threshold. None
    /// when we are not in saver-imposed mode.
    snapshot: Option<String>,
}

pub async fn run(cfg: BatteryConfig) -> Result<()> {
    let conn = Connection::system().await?;
    let dev = UPowerDeviceProxy::new(&conn)
        .await
        .context("connecting UPower DisplayDevice proxy")?;
    let ppd = Ppd::connect(&conn)
        .await
        .context("connecting power-profiles-daemon")?;

    let saver = Arc::new(Mutex::new(Saver::default()));
    let threshold = cfg.power_saver_percent;
    let hyst = cfg.hysteresis;

    // Initial evaluation so we converge even without an event soon.
    let init_pct = dev.percentage().await.unwrap_or(100.0) as u32;
    let init_state = dev.state().await.unwrap_or(1);
    info!(
        percentage = init_pct,
        state = init_state,
        threshold,
        hysteresis = hyst,
        "battery watcher started"
    );
    evaluate(&ppd, &saver, init_pct, init_state, threshold, hyst).await;

    // PropertiesChanged covers Percentage and State both. We re-read the
    // properties on every signal — UPower batches writes, so the signal
    // payload may not include the field we care about even if it changed.
    let mut changes = dev.receive_percentage_changed().await;
    let mut state_changes = dev.receive_state_changed().await;

    loop {
        tokio::select! {
            Some(c) = changes.next() => {
                let pct = c.get().await.unwrap_or(init_pct as f64) as u32;
                let st = dev.state().await.unwrap_or(init_state);
                debug!(percentage = pct, state = st, "percentage changed");
                evaluate(&ppd, &saver, pct, st, threshold, hyst).await;
            }
            Some(c) = state_changes.next() => {
                let st = c.get().await.unwrap_or(init_state);
                let pct = dev.percentage().await.unwrap_or(100.0) as u32;
                debug!(percentage = pct, state = st, "state changed");
                evaluate(&ppd, &saver, pct, st, threshold, hyst).await;
            }
            else => break,
        }
    }
    Ok(())
}

const STATE_CHARGING: u32 = 1;
const STATE_DISCHARGING: u32 = 2;
const STATE_FULLY_CHARGED: u32 = 4;

async fn evaluate(
    ppd: &Ppd<'_>,
    saver: &Arc<Mutex<Saver>>,
    pct: u32,
    state: u32,
    threshold: u32,
    hyst: u32,
) {
    let mut s = saver.lock().await;
    let on_battery = state == STATE_DISCHARGING;
    let charging = state == STATE_CHARGING || state == STATE_FULLY_CHARGED;

    // Descent: enter saver mode.
    if on_battery && pct <= threshold && s.snapshot.is_none() {
        let current = match ppd.get().await {
            Ok(p) => p,
            Err(e) => {
                warn!(error = %e, "cannot read PPD ActiveProfile; skipping");
                return;
            }
        };
        if current == "power-saver" {
            // Already in saver — record an empty marker so we don't try to
            // restore something we didn't change. Use "balanced" as the
            // sensible default to restore on AC.
            s.snapshot = Some("balanced".to_string());
            info!(
                pct,
                "battery low, profile already power-saver; will restore to balanced on AC"
            );
            return;
        }
        info!(
            pct,
            previous = %current,
            "battery low — switching to power-saver"
        );
        if let Err(e) = ppd.set("power-saver").await {
            warn!(error = %e, "failed to set power-saver");
            return;
        }
        s.snapshot = Some(current);
        return;
    }

    // Ascent: leave saver mode when we have a snapshot AND either
    //   * we're back above threshold + hysteresis, or
    //   * we're charging / fully charged.
    if let Some(prev) = s.snapshot.clone() {
        let above = pct >= threshold.saturating_add(hyst);
        if charging || (on_battery && above) {
            // Only restore if the active profile is still power-saver — the
            // user may have manually overridden it; we don't second-guess.
            let current = ppd.get().await.unwrap_or_default();
            if current == "power-saver" {
                info!(pct, restoring = %prev, charging, "restoring power profile");
                if let Err(e) = ppd.set(&prev).await {
                    warn!(error = %e, "failed to restore profile");
                    return;
                }
            } else {
                info!(
                    pct,
                    current = %current,
                    "battery recovered but user changed profile; clearing snapshot"
                );
            }
            s.snapshot = None;
        }
    }
}
