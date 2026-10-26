//! Process-wide status, shared by the phone session and the rest of the daemon.

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
}

pub fn global() -> &'static Global {
    static G: OnceLock<Global> = OnceLock::new();
    G.get_or_init(|| Global {
        phone: Mutex::new(None),
    })
}
