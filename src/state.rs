//! Process-wide status, shared by the phone session and the rest of the daemon.

use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Mutex, OnceLock};

use serde::Serialize;

#[derive(Clone, Serialize)]
pub struct PhoneInfo {
    pub ip: String,
    pub router: String,
    pub ifname: String,
}

pub struct Global {
    pub phone: Mutex<Option<PhoneInfo>>,
    pub usb_rx: AtomicU64,
    pub usb_tx: AtomicU64,
}

pub fn global() -> &'static Global {
    static G: OnceLock<Global> = OnceLock::new();
    G.get_or_init(|| Global {
        phone: Mutex::new(None),
        usb_rx: AtomicU64::new(0),
        usb_tx: AtomicU64::new(0),
    })
}

pub fn add(counter: &AtomicU64, n: usize) {
    counter.fetch_add(n as u64, Relaxed);
}
