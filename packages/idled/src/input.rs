// Input device watcher.
//
// Opens every /dev/input/event* device that looks like a keyboard, pointer,
// or touchpad, and converts its event stream into ticks on the supplied
// channel. Watches /dev/input/ with inotify so hot-plugged devices (USB
// keyboard, bluetooth mouse) are picked up live.
//
// We deliberately ignore EV_SW-only devices (lid switch, tablet-mode switch)
// and EV_KEY devices that only carry KEY_POWER / KEY_SLEEP so that closing
// the lid does not count as activity.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use evdev::{Device, EventType, Key};
use futures_util::StreamExt;
use inotify::{EventMask, Inotify, WatchMask};
use tokio::sync::mpsc::UnboundedSender;
use tracing::{debug, info, warn};

const INPUT_DIR: &str = "/dev/input";

pub async fn watch_all(tx: UnboundedSender<()>) -> Result<()> {
    // Open every existing event device.
    let entries = std::fs::read_dir(INPUT_DIR)
        .with_context(|| format!("reading {}", INPUT_DIR))?;
    for ent in entries.flatten() {
        let path = ent.path();
        if !is_event_node(&path) {
            continue;
        }
        try_attach(&path, tx.clone());
    }

    // Hot-plug: watch for new event* nodes appearing.
    let inotify = Inotify::init().context("inotify init")?;
    inotify
        .watches()
        .add(INPUT_DIR, WatchMask::CREATE | WatchMask::ATTRIB)
        .context("inotify add_watch")?;
    let buffer = [0u8; 4096];
    let mut stream = inotify
        .into_event_stream(buffer)
        .context("inotify event_stream")?;
    while let Some(ev) = stream.next().await {
        let ev = match ev {
            Ok(e) => e,
            Err(e) => {
                warn!(error = %e, "inotify error");
                continue;
            }
        };
        if !ev.mask.intersects(EventMask::CREATE | EventMask::ATTRIB) {
            continue;
        }
        let name = match ev.name.as_ref() {
            Some(n) => n,
            None => continue,
        };
        let path = PathBuf::from(INPUT_DIR).join(name);
        if !is_event_node(&path) {
            continue;
        }
        // ATTRIB also fires for permission changes after udev settles; fine to
        // double-attempt because try_attach retries once and is idempotent.
        try_attach(&path, tx.clone());
    }
    Ok(())
}

fn is_event_node(path: &Path) -> bool {
    path.file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.starts_with("event"))
        .unwrap_or(false)
}

fn try_attach(path: &Path, tx: UnboundedSender<()>) {
    let p = path.to_path_buf();
    tokio::spawn(async move {
        // Tiny delay so udev can chmod the node into the input group on
        // hot-plug; trying immediately on CREATE often races and gives EACCES.
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        let dev = match Device::open(&p) {
            Ok(d) => d,
            Err(e) => {
                debug!(path = %p.display(), error = %e, "cannot open device");
                return;
            }
        };
        if !is_user_input_device(&dev) {
            debug!(path = %p.display(), name = ?dev.name(), "skipping non-user-input device");
            return;
        }
        let name = dev.name().unwrap_or("?").to_string();
        info!(path = %p.display(), name = %name, "watching input device");
        let mut stream = match dev.into_event_stream() {
            Ok(s) => s,
            Err(e) => {
                warn!(path = %p.display(), error = %e, "cannot create event stream");
                return;
            }
        };
        loop {
            match stream.next_event().await {
                Ok(_) => {
                    // Any event from a qualifying device counts as activity.
                    // Don't try to filter further — hardware key autorepeat,
                    // touchpad coast, etc., are all fine signals of presence.
                    if tx.send(()).is_err() {
                        return; // main loop gone
                    }
                }
                Err(e) => {
                    warn!(path = %p.display(), error = %e, "event stream error; closing");
                    return;
                }
            }
        }
    });
}

fn is_user_input_device(dev: &Device) -> bool {
    let evs = dev.supported_events();
    // Pointer-like: any relative motion (mouse) OR touchpad-style absolute
    // axes alongside EV_KEY (touchpads report BTN_TOUCH on EV_KEY plus
    // ABS_X/ABS_Y on EV_ABS).
    if evs.contains(EventType::RELATIVE) {
        return true;
    }
    if evs.contains(EventType::KEY) {
        if let Some(keys) = dev.supported_keys() {
            // Keyboard: any letter present (KEY_A=30, KEY_Z=44 in evdev numbering).
            for k in [
                Key::KEY_A,
                Key::KEY_E,
                Key::KEY_SPACE,
                Key::KEY_ENTER,
                Key::KEY_TAB,
                Key::KEY_BACKSPACE,
            ] {
                if keys.contains(k) {
                    return true;
                }
            }
            // Pointer buttons: mouse / trackpoint / touchpad click.
            for b in [
                Key::BTN_LEFT,
                Key::BTN_RIGHT,
                Key::BTN_MIDDLE,
                Key::BTN_TOUCH,
            ] {
                if keys.contains(b) {
                    return true;
                }
            }
        }
    }
    false
}
