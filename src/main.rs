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
use std::io::{self, Write};
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

/// Write one timestamped line to stderr. Never panics: a full disk or a
/// closed log must not take down whichever thread is logging.
pub fn log_line(args: std::fmt::Arguments) {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        libc::localtime_r(&t, &mut tm);
    }
    let line = format!(
        "{:02}:{:02}:{:02} {args}\n",
        tm.tm_hour, tm.tm_min, tm.tm_sec
    );
    let _ = io::stderr().write_all(line.as_bytes());
    rotate_log();
}

/// Like `eprintln!` for the start-up messages, but never panics.
macro_rules! say {
    ($($a:tt)*) => {{
        let _ = writeln!(io::stderr(), $($a)*);
    }};
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

/// Position of the device `id` in a fresh scan. A queued candidate may come
/// from a scan taken before the last session ended; the session always opens
/// the fresh enumeration entry, and skips the device if it is gone.
fn fresh_index<'a>(id: &DeviceId, mut fresh: impl Iterator<Item = &'a DeviceId>) -> Option<usize> {
    fresh.position(|f| f == id)
}

/// Hand-off from the supervisor to the session loop. The queued device and
/// "a session is starting or running" live under one lock, so nothing can be
/// queued between a take and the session start, or while a session runs.
struct Handoff<T> {
    slot: Option<T>,
    busy: bool,
}

impl<T> Handoff<T> {
    fn new() -> Self {
        Handoff {
            slot: None,
            busy: false,
        }
    }

    /// Supervisor: queue `item` unless a session is running or one is queued.
    fn offer(&mut self, item: T) -> bool {
        if self.busy || self.slot.is_some() {
            return false;
        }
        self.slot = Some(item);
        true
    }

    /// Session loop: take the queued device and mark the hand-off busy.
    fn take(&mut self) -> Option<T> {
        let item = self.slot.take();
        if item.is_some() {
            self.busy = true;
        }
        item
    }

    /// The session (or the attempt to start one) is over: drop anything that
    /// was queued meanwhile and accept new offers.
    fn finish(&mut self) {
        self.slot = None;
        self.busy = false;
    }
}

/// Set when a worker thread ended while the daemon was not stopping.
static WORKER_DIED: AtomicBool = AtomicBool::new(false);

/// A worker thread (supervisor, control socket) that panics, or that ends
/// while nobody asked the daemon to stop, has died.
fn worker_died(panicking: bool, quitting: bool) -> bool {
    panicking || !quitting
}

/// The main loop's check on the workers' `JoinHandle`s.
fn worker_stopped(finished: &[bool], quitting: bool) -> bool {
    !quitting && finished.iter().any(|&f| f)
}

/// Lives on a worker thread's stack. When the thread ends unexpectedly (even
/// by a panic), it stops the daemon: QUIT ends any running session normally,
/// so its routes and DNS are removed, and main then exits non-zero so that
/// launchd's KeepAlive starts a fresh daemon.
pub struct WorkerGuard(pub &'static str);

impl Drop for WorkerGuard {
    fn drop(&mut self) {
        if worker_died(thread::panicking(), QUIT.load(Relaxed)) {
            log!(
                "{} thread stopped unexpectedly; shutting down so launchd restarts usbtetherd",
                self.0
            );
            WORKER_DIED.store(true, Relaxed);
            QUIT.store(true, Relaxed);
        }
    }
}

const MAX_PANICS_IN_A_ROW: u32 = 5;

/// Run `pass` until `quit` is set, calling `pause` after each pass. A pass
/// that panics is logged and the next one runs; after `MAX_PANICS_IN_A_ROW`
/// panics in a row this gives up and returns true.
fn run_passes(quit: &AtomicBool, mut pass: impl FnMut(), mut pause: impl FnMut()) -> bool {
    let mut panics = 0;
    while !quit.load(Relaxed) {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(&mut pass)) {
            Ok(()) => panics = 0,
            Err(_) => {
                panics += 1;
                log!("supervisor pass panicked ({panics} in a row)");
                if panics >= MAX_PANICS_IN_A_ROW {
                    return true;
                }
            }
        }
        pause();
    }
    false
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

/// The supervisor's state carried from one pass to the next.
#[derive(Default)]
struct Supervisor {
    console_prev: Option<u32>,
    console_polled: Option<Instant>,
    newly_prompted: bool,
}

impl Supervisor {
    /// Scan, gate, prompt, queue an approved device, launch the approval app.
    fn pass(&mut self, ctx: &Mutex<Ctx>, handoff: &Mutex<Handoff<Candidate>>) {
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
                self.newly_prompted = true;
            }
        }

        if let Some(i) = pick_connect(&decisions, active.as_ref())
            && let Some(cand) = candidates.into_iter().nth(i)
        {
            handoff
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .offer(cand);
        }

        if self
            .console_polled
            .is_none_or(|t| t.elapsed() >= CONSOLE_POLL)
        {
            self.console_polled = Some(Instant::now());
            let now = launcher::console_uid();
            if launcher::should_launch(
                self.console_prev,
                now,
                self.newly_prompted,
                pending_nonempty,
            ) && let Some(uid) = now
                && let Err(e) = launcher::launch_app(uid)
            {
                log!("could not launch the approval app: {e}");
            }
            self.console_prev = now;
            self.newly_prompted = false;
        }
    }
}

/// Scan, gate, prompt and launch the approval app, once a second, for the
/// whole life of the daemon (sessions run on the main thread meanwhile).
/// The Ctx lock is held only for the gate decisions, never across a scan,
/// a launch or a session.
fn supervise(ctx: &Mutex<Ctx>, handoff: &Mutex<Handoff<Candidate>>) {
    let mut sup = Supervisor::default();
    let gave_up = run_passes(
        &QUIT,
        || sup.pass(ctx, handoff),
        || sleep_unless_quit(Duration::from_secs(1)),
    );
    if gave_up {
        log!("supervisor keeps panicking; giving up");
    }
}

/// What the session loop does once a session has ended.
#[derive(Debug, PartialEq, Eq)]
enum After {
    /// The daemon is stopping.
    Quit,
    /// The phone's approval was removed; it is not used until approved again.
    Revoked,
    /// The phone went away (or tethering was switched off).
    Disconnected,
    /// The session failed; try again after a pause.
    Retry,
}

fn after_session(ok: bool, quit: bool, revoked: bool) -> After {
    if quit {
        After::Quit
    } else if revoked {
        After::Revoked
    } else if ok {
        After::Disconnected
    } else {
        After::Retry
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
    let next = after_session(result.is_ok(), QUIT.load(Relaxed), revoke.load(Relaxed));
    match (next, result) {
        (After::Quit, Err(e)) => log!("{e}"),
        (After::Quit, Ok(())) => {}
        (After::Revoked, _) => {
            log!("approval removed; this phone is not used until it is approved again")
        }
        (After::Disconnected, _) => log!("phone disconnected; waiting for it to come back"),
        (After::Retry, Err(e)) => {
            log!("{e}; retrying in 3s");
            sleep_unless_quit(Duration::from_secs(3));
        }
        (After::Retry, Ok(())) => {}
    }
}

fn main() {
    if unsafe { libc::geteuid() } != 0 {
        say!(
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
            say!("usage: sudo usbtetherd [--test]   (unknown argument: {other})");
            std::process::exit(2);
        }
    }
    if let Some(pid) = running_pid() {
        say!("usbtetherd is already running (pid {pid})");
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
    let control = match control::serve(ctx.clone()) {
        Ok(h) => Some(h),
        Err(e) => {
            log!("warning: control socket unavailable ({e}); new phones cannot be approved");
            None
        }
    };
    log!("waiting for an approved phone — plug it in and turn on USB tethering");

    // The supervisor keeps scanning, prompting and launching the app while a
    // session blocks this thread; it hands over at most one approved device.
    // Lock order where both are held: handoff, then ctx.
    let handoff: Arc<Mutex<Handoff<Candidate>>> = Arc::new(Mutex::new(Handoff::new()));
    let supervisor = {
        let (ctx, handoff) = (ctx.clone(), handoff.clone());
        thread::Builder::new()
            .name("usbtether-supervisor".into())
            .spawn(move || {
                let _guard = WorkerGuard("supervisor");
                supervise(&ctx, &handoff)
            })
            .expect("spawn supervisor")
    };

    while !QUIT.load(Relaxed) {
        let finished = [
            supervisor.is_finished(),
            control.as_ref().is_some_and(|h| h.is_finished()),
        ];
        if worker_stopped(&finished, QUIT.load(Relaxed)) {
            log!("a worker thread has stopped; shutting down so launchd restarts usbtetherd");
            WORKER_DIED.store(true, Relaxed);
            QUIT.store(true, Relaxed);
            break;
        }
        // Take the queued device, mark the hand-off busy, re-check the
        // allowlist (defence in depth) and mark the device active, all in one
        // critical section: a later Remove cannot be lost, and nothing can be
        // queued while the session starts.
        let cand = {
            let mut h = handoff.lock().unwrap_or_else(|e| e.into_inner());
            let Some(cand) = h.take() else {
                drop(h);
                thread::sleep(Duration::from_millis(200));
                continue;
            };
            let mut c = ctx.lock().unwrap_or_else(|e| e.into_inner());
            if !c.store.is_approved(&cand.id) {
                h.finish();
                continue;
            }
            c.active = Some(cand.id.clone());
            revoke.store(false, Relaxed);
            cand
        };
        // The queued entry may be from a scan taken before the last session
        // ended: open the phone's fresh enumeration entry, or skip it if gone.
        let mut fresh = discovery::scan();
        if let Some(i) = fresh_index(&cand.id, fresh.iter().map(|c| &c.id)) {
            // Neither lock is held while the session runs.
            run_session(fresh.swap_remove(i).info, &revoke, test);
        }
        let mut h = handoff.lock().unwrap_or_else(|e| e.into_inner());
        ctx.lock().unwrap_or_else(|e| e.into_inner()).active = None;
        h.finish();
    }
    let _ = supervisor.join();

    sysnet::remove_dns();
    let _ = fs::remove_file(control::SOCKET);
    let _ = fs::remove_file(PIDFILE);
    log!("stopped; normal networking restored");
    if WORKER_DIED.load(Relaxed) {
        // Non-zero so launchd's KeepAlive treats this as a failure and starts
        // a fresh daemon. No session is running here: its routes and DNS
        // were removed when it ended.
        std::process::exit(1);
    }
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

    #[test]
    fn handoff_take_marks_busy_so_nothing_is_queued_during_a_session() {
        let mut h = Handoff::new();
        assert_eq!(h.take(), None);
        assert!(!h.busy, "an empty take must not mark the hand-off busy");
        assert!(h.offer(1));
        assert!(!h.offer(2), "one queued device at a time");
        assert_eq!(h.take(), Some(1));
        assert!(h.busy);
        // The supervisor's offer between the take and the session start, or
        // during the session, is refused under the same lock.
        assert!(!h.offer(3));
        assert_eq!(h.take(), None);
        h.finish();
        assert!(!h.busy);
        assert!(h.offer(4));
        assert_eq!(h.take(), Some(4));
    }

    #[test]
    fn handoff_finish_drops_anything_queued_before_the_session_ended() {
        let mut h = Handoff::new();
        assert!(h.offer(1));
        assert_eq!(h.take(), Some(1));
        h.slot = Some(9); // stale entry (must never be served after the session)
        h.finish();
        assert_eq!(h.slot, None);
        assert_eq!(h.take(), None);
    }

    #[test]
    fn fresh_candidate_is_found_by_id_or_skipped() {
        let fresh = [id(2), id(1)];
        assert_eq!(fresh_index(&id(1), fresh.iter()), Some(1));
        assert_eq!(fresh_index(&id(3), fresh.iter()), None);
        assert_eq!(fresh_index(&id(1), [].iter()), None);
    }

    #[test]
    fn worker_thread_end_is_a_death_unless_the_daemon_is_stopping() {
        assert!(worker_died(true, false));
        assert!(worker_died(true, true), "a panic is always a death");
        assert!(worker_died(false, false), "a worker must never just return");
        assert!(!worker_died(false, true), "normal return at shutdown");
    }

    #[test]
    fn main_loop_stops_when_any_worker_finished() {
        assert!(!worker_stopped(&[false, false], false));
        assert!(worker_stopped(&[true, false], false));
        assert!(worker_stopped(&[false, true], false));
        assert!(
            !worker_stopped(&[true, true], true),
            "finishing at shutdown is fine"
        );
        assert!(!worker_stopped(&[], false));
    }

    #[test]
    fn passes_survive_a_panic_and_stop_on_quit() {
        let quit = AtomicBool::new(false);
        let mut calls = 0;
        let gave_up = run_passes(
            &quit,
            || {
                calls += 1;
                if calls == 2 {
                    panic!("one bad pass");
                }
                if calls == 5 {
                    quit.store(true, Relaxed);
                }
            },
            || {},
        );
        assert!(!gave_up);
        assert_eq!(calls, 5);
    }

    #[test]
    fn passes_give_up_after_repeated_panics() {
        let quit = AtomicBool::new(false);
        let mut calls = 0;
        let gave_up = run_passes(
            &quit,
            || {
                calls += 1;
                panic!("always broken");
            },
            || {},
        );
        assert!(gave_up);
        assert_eq!(calls, MAX_PANICS_IN_A_ROW);
    }

    #[test]
    fn after_session_retries_only_real_errors() {
        assert_eq!(after_session(true, false, false), After::Disconnected);
        assert_eq!(after_session(false, false, false), After::Retry);
        assert_eq!(after_session(false, true, false), After::Quit);
        assert_eq!(after_session(true, true, true), After::Quit);
        // An ended approval is neither a disconnect nor a retryable error.
        assert_eq!(after_session(false, false, true), After::Revoked);
        assert_eq!(after_session(true, false, true), After::Revoked);
    }

    const LOG_CHILD: &str = "USBTETHER_LOG_CHILD";

    /// Runs only inside the child process started by the test below.
    #[test]
    fn log_line_child() {
        if std::env::var_os(LOG_CHILD).is_none() {
            return;
        }
        for _ in 0..3 {
            log!("stderr is a broken pipe");
        }
    }

    #[test]
    fn log_line_does_not_panic_when_stderr_is_broken() {
        use std::process::{Command, Stdio};
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "tests::log_line_child", "--nocapture"])
            .env(LOG_CHILD, "1")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // Close the read end: every write to the child's stderr now fails (EPIPE).
        drop(child.stderr.take());
        assert!(child.wait().unwrap().success());
    }
}
