//! usbtetherd — Android (Samsung) USB tethering for macOS.
//!
//! macOS has no driver for RNDIS, the protocol Samsung's USB tethering speaks.
//! This is a userspace one: it claims the phone's RNDIS interfaces through
//! IOKit (via nusb), speaks RNDIS, and moves packets between the phone and a
//! utun interface. Turn on USB tethering on the phone and it just works.
//!
//! Usage: sudo usbtetherd         run in the foreground (Ctrl+C to stop)
//!        sudo usbtetherd --test  bring the link up but route only bound sockets over it

mod devices;
mod packet;
mod rndis;
mod session;
mod state;
mod sysnet;
mod utun;

use std::fs;
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::thread;
use std::time::Duration;

const PIDFILE: &str = "/var/run/usbtetherd.pid";

pub const VERSION: &str = match option_env!("USBTETHER_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

static QUIT: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_: libc::c_int) {
    QUIT.store(true, Relaxed);
}

const LOG_PATH: &str = "/var/log/usbtether.log";
const LOG_MAX: i64 = 1_000_000;

pub fn log_line(args: std::fmt::Arguments) {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        libc::localtime_r(&t, &mut tm);
    }
    eprintln!("{:02}:{:02}:{:02} {args}", tm.tm_hour, tm.tm_min, tm.tm_sec);
    rotate_log();
}

/// Under launchd, stderr is /var/log/usbtether.log opened for appending.
/// Keep it bounded: past 1 MB, copy it to .1 and truncate in place (writes
/// continue at the new end because the file is in append mode).
fn rotate_log() {
    use std::sync::atomic::AtomicU32;
    static LINES: AtomicU32 = AtomicU32::new(0);
    if !LINES.fetch_add(1, Relaxed).is_multiple_of(100) {
        return;
    }
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    let regular =
        unsafe { libc::fstat(2, &mut st) } == 0 && st.st_mode & libc::S_IFMT == libc::S_IFREG;
    if regular && st.st_size > LOG_MAX {
        let old = format!("{LOG_PATH}.1");
        if fs::copy(LOG_PATH, &old).is_ok() {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&old, fs::Permissions::from_mode(0o640));
            unsafe { libc::ftruncate(2, 0) };
        }
    }
}

#[macro_export]
macro_rules! log {
    ($($a:tt)*) => { $crate::log_line(format_args!($($a)*)) };
}

/// The PID in the pidfile, if that process is alive *and is usbtetherd*: a
/// stale file after a crash must not make us signal whoever reused the PID.
fn running_pid() -> Option<i32> {
    let pid: i32 = fs::read_to_string(PIDFILE).ok()?.trim().parse().ok()?;
    if pid <= 0 || pid as u32 == std::process::id() {
        return None;
    }
    let mut buf = vec![0u8; 4096];
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if n <= 0 {
        return None;
    }
    let path = String::from_utf8_lossy(&buf[..n as usize]).into_owned();
    let is_usbtetherd = std::path::Path::new(&path)
        .file_name()
        .is_some_and(|f| f == "usbtetherd");
    is_usbtetherd.then_some(pid)
}

fn main() {
    if unsafe { libc::geteuid() } != 0 {
        eprintln!(
            "usbtetherd needs root to create a network interface: sudo {}",
            std::env::args().collect::<Vec<_>>().join(" ")
        );
        std::process::exit(1);
    }
    let mut test = false;
    match std::env::args().nth(1).as_deref() {
        None => {}
        Some("--test") => test = true,
        Some(other) => {
            eprintln!("usage: sudo usbtetherd [--test]   (unknown argument: {other})");
            std::process::exit(2);
        }
    }
    if let Some(pid) = running_pid() {
        eprintln!("usbtetherd is already running (pid {pid})");
        std::process::exit(1);
    }

    unsafe {
        for sig in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
            libc::signal(sig, on_signal as *const () as libc::sighandler_t);
        }
    }
    let _ = fs::write(PIDFILE, std::process::id().to_string());
    sysnet::remove_dns(); // anything left by an earlier run
    if let Err(e) = sysnet::spawn_guard() {
        log!("warning: could not start the cleanup guard: {e}");
    }

    log!("usbtetherd {VERSION} starting");
    log!("waiting for the phone — plug it in and turn on USB tethering");
    let mut waiting_logged = true;
    while !QUIT.load(Relaxed) {
        match session::find_phone() {
            Some(info) => {
                waiting_logged = false;
                // A panic in a session (bad input from a device) must not
                // take the daemon down: unwinding drops the session's routes
                // and DNS, and we go back to waiting.
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    session::run(info, &QUIT, test)
                }))
                .unwrap_or_else(|_| Err(std::io::Error::other("session crashed")));
                match result {
                    Ok(()) if !QUIT.load(Relaxed) => {
                        log!("phone disconnected; waiting for it to come back")
                    }
                    Ok(()) => {}
                    Err(e) if QUIT.load(Relaxed) => log!("{e}"),
                    Err(e) => {
                        log!("{e}; retrying in 3s");
                        thread::sleep(Duration::from_secs(3));
                    }
                }
            }
            None => {
                if !waiting_logged {
                    log!("waiting for the phone — plug it in and turn on USB tethering");
                    waiting_logged = true;
                }
                thread::sleep(Duration::from_secs(1));
            }
        }
    }

    sysnet::remove_dns();
    let _ = fs::remove_file(PIDFILE);
    log!("stopped; normal networking restored");
}
