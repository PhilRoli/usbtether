//! usbtetherd — Android (Samsung) USB tethering for macOS.
//!
//! macOS has no driver for RNDIS, the protocol Samsung's USB tethering speaks.
//! This is a userspace one: it claims the phone's RNDIS interfaces through
//! IOKit (via nusb), speaks RNDIS, and moves packets between the phone and a
//! utun interface. Turn on USB tethering on the phone and it just works.
//!
//! Usage: sudo usbtetherd         run in the foreground (Ctrl+C to stop)
//!        sudo usbtetherd --test  bring the link up but route only bound sockets over it

mod control;
mod devices;
mod discovery;
mod gate;
mod launcher;
mod packet;
mod rndis;
mod session;
mod state;
mod sysnet;
mod utun;

use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use control::Ctx;
use devices::{DeviceId, STORE_PATH, Store};
use discovery::Candidate;
use gate::{Decision, Gate};

const CONSOLE_POLL: Duration = Duration::from_secs(2);
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

/// Index of the device to connect: the first `Connect` that is not the device
/// already being served.
fn pick_connect(decisions: &[(DeviceId, Decision)], active: Option<&DeviceId>) -> Option<usize> {
    decisions
        .iter()
        .position(|(id, d)| *d == Decision::Connect && Some(id) != active)
}

fn sleep_unless_quit(total: Duration) {
    let step = Duration::from_millis(100);
    let mut left = total;
    while !left.is_zero() && !QUIT.load(Relaxed) {
        let d = step.min(left);
        thread::sleep(d);
        left -= d;
    }
}

/// Scan, gate, prompt and launch the approval app, once a second, for the
/// whole life of the daemon (sessions run on the main thread meanwhile).
/// The Ctx lock is held only for the gate decisions, never across a scan,
/// a launch or a session.
fn supervise(ctx: &Mutex<Ctx>, slot: &Mutex<Option<Candidate>>, busy: &AtomicBool) {
    let mut console_prev: Option<u32> = None;
    let mut console_polled: Option<Instant> = None;
    let mut newly_prompted = false;
    while !QUIT.load(Relaxed) {
        let candidates = discovery::scan();
        let present: Vec<DeviceId> = candidates.iter().map(|c| c.id.clone()).collect();
        let (decisions, active, pending_nonempty) = {
            let mut c = ctx.lock().unwrap_or_else(|e| e.into_inner());
            let active = c.active.clone();
            let Ctx { gate, store, .. } = &mut *c;
            gate.device_gone(&present);
            let decisions: Vec<(DeviceId, Decision)> = candidates
                .iter()
                .map(|cand| (cand.id.clone(), gate.evaluate(&cand.id, &cand.name, store)))
                .collect();
            (decisions, active, !gate.pending().is_empty())
        };

        for (cand, (_, decision)) in candidates.iter().zip(&decisions) {
            if matches!(decision, Decision::Prompt(_)) {
                log!(
                    "unapproved device {} {:04x}:{:04x} waiting for approval",
                    cand.name,
                    cand.id.vid,
                    cand.id.pid
                );
                newly_prompted = true;
            }
        }

        if !busy.load(Relaxed)
            && let Some(i) = pick_connect(&decisions, active.as_ref())
        {
            let mut s = slot.lock().unwrap_or_else(|e| e.into_inner());
            if s.is_none() {
                *s = candidates.into_iter().nth(i);
            }
        }

        if console_polled.is_none_or(|t| t.elapsed() >= CONSOLE_POLL) {
            console_polled = Some(Instant::now());
            let now = launcher::console_uid();
            if launcher::should_launch(console_prev, now, newly_prompted, pending_nonempty)
                && let Some(uid) = now
                && let Err(e) = launcher::launch_app(uid)
            {
                log!("could not launch the approval app: {e}");
            }
            console_prev = now;
            newly_prompted = false;
        }

        sleep_unless_quit(Duration::from_secs(1));
    }
}

/// Run one phone session on this thread. A panic (bad input from a device)
/// must not take the daemon down: unwinding drops the session's routes and
/// DNS, and we go back to scanning.
fn run_session(info: nusb::DeviceInfo, revoke: &AtomicBool, test: bool) {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        session::run(info, &QUIT, revoke, test)
    }))
    .unwrap_or_else(|_| Err(std::io::Error::other("session crashed")));
    // A panicking session never reached its own cleanup of the status.
    *state::global()
        .phone
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = None;
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
    let revoke = Arc::new(AtomicBool::new(false));
    let ctx = Arc::new(Mutex::new(Ctx {
        gate: Gate::new(),
        store: Store::load(Path::new(STORE_PATH), 0),
        phone: None,
        active: None,
        revoke: revoke.clone(),
    }));
    if let Err(e) = control::serve(ctx.clone()) {
        log!("warning: control socket unavailable ({e}); new phones cannot be approved");
    }
    log!("waiting for an approved phone — plug it in and turn on USB tethering");

    // The supervisor keeps scanning, prompting and launching the app while a
    // session blocks this thread; it hands over at most one approved device.
    let slot: Arc<Mutex<Option<Candidate>>> = Arc::new(Mutex::new(None));
    let busy = Arc::new(AtomicBool::new(false));
    let supervisor = {
        let (ctx, slot, busy) = (ctx.clone(), slot.clone(), busy.clone());
        thread::Builder::new()
            .name("usbtether-supervisor".into())
            .spawn(move || supervise(&ctx, &slot, &busy))
            .expect("spawn supervisor")
    };

    while !QUIT.load(Relaxed) {
        let taken = slot.lock().unwrap_or_else(|e| e.into_inner()).take();
        let Some(cand) = taken else {
            thread::sleep(Duration::from_millis(200));
            continue;
        };
        busy.store(true, Relaxed);
        {
            // Defence in depth: re-check the allowlist right before touching
            // the phone. Marking it active and resetting revoke happen under
            // the same lock as the check, so a later Remove cannot be lost.
            let mut c = ctx.lock().unwrap_or_else(|e| e.into_inner());
            if !c.store.is_approved(&cand.id) {
                busy.store(false, Relaxed);
                continue;
            }
            c.active = Some(cand.id.clone());
            revoke.store(false, Relaxed);
        }
        // The Ctx lock is not held while the session runs.
        run_session(cand.info, &revoke, test);
        ctx.lock().unwrap_or_else(|e| e.into_inner()).active = None;
        busy.store(false, Relaxed);
    }
    let _ = supervisor.join();

    sysnet::remove_dns();
    let _ = fs::remove_file(PIDFILE);
    log!("stopped; normal networking restored");
}

#[cfg(test)]
mod tests {
    use super::*;
    use devices::ApprovedDevice;

    fn id(pid: u16) -> DeviceId {
        DeviceId {
            vid: 0x04e8,
            pid,
            serial: Some(format!("S{pid}")),
        }
    }

    #[test]
    fn approved_and_unapproved_both_present_connect_picks_approved_and_other_still_prompts() {
        let dir = std::env::temp_dir().join(format!("usbtether-maintest-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let mut store = Store::load(&dir.join("devices.json"), unsafe { libc::geteuid() });
        store
            .add(ApprovedDevice {
                id: id(1),
                name: "A".into(),
                approved_at: 1,
            })
            .unwrap();
        let mut gate = Gate::new();
        // unapproved one is listed first
        let decisions = vec![
            (id(2), gate.evaluate(&id(2), "B", &store)),
            (id(1), gate.evaluate(&id(1), "A", &store)),
        ];
        assert!(matches!(decisions[0].1, Decision::Prompt(_)));
        assert_eq!(pick_connect(&decisions, None), Some(1));
        assert_eq!(gate.pending().len(), 1);
        // the device already being served is not offered again
        assert_eq!(pick_connect(&decisions, Some(&id(1))), None);
        let _ = fs::remove_dir_all(&dir);
    }
}
