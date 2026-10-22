//! Local control socket: one JSON request per line, one JSON reply per line.
//! Only root and members of the `admin` group get any answer; the check uses
//! the peer's credentials (checked before reading), not file permissions.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::devices::{DeviceId, Store};
use crate::gate::{Gate, GateError};
use crate::state::{self, PhoneInfo};

pub const SOCKET: &str = "/var/run/usbtether.sock";
const ADMIN_GID: libc::gid_t = 80;
const MAX_REQUEST: u64 = 64 * 1024;
const REQUEST_DEADLINE: Duration = Duration::from_secs(2);

pub struct Ctx {
    pub gate: Gate,
    pub store: Store,
    pub phone: Option<PhoneInfo>,
}

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Request {
    Status,
    Approve {
        request_id: String,
    },
    Decline {
        request_id: String,
    },
    Remove {
        vid: u16,
        pid: u16,
        serial: Option<String>,
    },
}

fn error_reply(msg: &str) -> String {
    serde_json::json!({ "error": msg }).to_string()
}

fn status_reply(ctx: &Ctx) -> String {
    let pending: Vec<_> = ctx
        .gate
        .pending()
        .into_iter()
        .map(|p| {
            serde_json::json!({
                "request_id": p.request_id,
                "name": p.name,
                "vid": p.id.vid,
                "pid": p.id.pid,
                "serial": p.id.serial,
            })
        })
        .collect();
    let approved: Vec<_> = ctx
        .store
        .list()
        .iter()
        .map(|d| {
            serde_json::json!({
                "name": d.name,
                "vid": d.id.vid,
                "pid": d.id.pid,
                "serial": d.id.serial,
                "approved_at": d.approved_at,
            })
        })
        .collect();
    serde_json::json!({
        "phone": ctx.phone,
        "pending": pending,
        "approved": approved,
    })
    .to_string()
}

/// Apply one request line and return the single JSON reply (no newline).
pub fn handle(line: &str, ctx: &mut Ctx) -> String {
    let req = match serde_json::from_str::<Request>(line) {
        Ok(r) => r,
        Err(e) => return error_reply(&e.to_string()),
    };
    match req {
        Request::Status => {}
        Request::Approve { request_id } => {
            let Ctx { gate, store, .. } = &mut *ctx;
            match gate.approve(&request_id, store) {
                Ok(()) => {}
                Err(GateError::UnknownRequest) => return error_reply("unknown request id"),
                Err(GateError::Store(e)) => {
                    return error_reply(&format!("store write failed: {e}"));
                }
            }
        }
        Request::Decline { request_id } => {
            if ctx.gate.decline(&request_id).is_err() {
                return error_reply("unknown request id");
            }
        }
        Request::Remove { vid, pid, serial } => {
            let id = DeviceId { vid, pid, serial };
            if let Err(e) = ctx.store.remove(&id) {
                return error_reply(&format!("store write failed: {e}"));
            }
        }
    }
    status_reply(ctx)
}

/// Fails with `TimedOut` once `limit` has elapsed since creation, checked
/// before every read (per-read socket timeouts alone let a slow drip last forever).
struct Deadline<R> {
    inner: R,
    start: Instant,
    limit: Duration,
}

impl<R: Read> Read for Deadline<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.start.elapsed() >= self.limit {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "request took too long",
            ));
        }
        self.inner.read(buf)
    }
}

/// Read one request line, refusing anything over `MAX_REQUEST` bytes or
/// taking longer than `limit` in total.
pub fn read_request(r: impl Read, limit: Duration) -> io::Result<String> {
    let r = Deadline {
        inner: r,
        start: Instant::now(),
        limit,
    };
    let mut line = String::new();
    BufReader::new(r.take(MAX_REQUEST + 1)).read_line(&mut line)?;
    if line.len() as u64 > MAX_REQUEST {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "request too large",
        ));
    }
    Ok(line)
}

fn is_admin(uid: libc::uid_t) -> bool {
    unsafe {
        let pw = libc::getpwuid(uid);
        if pw.is_null() {
            return false;
        }
        let mut groups = [0 as libc::c_int; 64];
        let mut n = groups.len() as libc::c_int;
        libc::getgrouplist(
            (*pw).pw_name,
            (*pw).pw_gid as libc::c_int,
            groups.as_mut_ptr(),
            &mut n,
        );
        // On overflow n reports the size needed, not what was filled.
        let filled = (n.max(0) as usize).min(groups.len());
        groups[..filled].contains(&(ADMIN_GID as libc::c_int))
    }
}

pub fn peer_allowed(uid: u32, in_admin_group: impl Fn(u32) -> bool) -> bool {
    uid == 0 || in_admin_group(uid)
}

fn stream_peer_allowed(s: &UnixStream) -> bool {
    let (mut uid, mut gid) = (0, 0);
    let r = unsafe { libc::getpeereid(s.as_raw_fd(), &mut uid, &mut gid) };
    r == 0 && peer_allowed(uid, is_admin)
}

fn current_phone() -> Option<PhoneInfo> {
    state::global()
        .phone
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Serve one connection. `allowed` is the peer verdict, decided before any
/// byte of the request is read. The `Ctx` lock is held only inside `handle`.
fn serve_conn<S: Read + Write>(s: &mut S, allowed: bool, ctx: &Mutex<Ctx>) -> io::Result<()> {
    if !allowed {
        return s.write_all(b"{\"error\":\"not allowed\"}\n");
    }
    let reply = match read_request(&mut *s, REQUEST_DEADLINE) {
        Ok(line) => {
            let phone = current_phone();
            let mut c = ctx.lock().unwrap_or_else(|e| e.into_inner());
            c.phone = phone;
            handle(&line, &mut c)
        }
        Err(e) => error_reply(&e.to_string()),
    };
    s.write_all(reply.as_bytes())?;
    s.write_all(b"\n")
}

pub fn serve(ctx: Arc<Mutex<Ctx>>) -> io::Result<()> {
    let _ = std::fs::remove_file(SOCKET);
    let listener = UnixListener::bind(SOCKET)?;
    // Anyone may connect; the per-connection peer check decides who gets an answer.
    std::fs::set_permissions(SOCKET, std::fs::Permissions::from_mode(0o666))?;
    std::thread::Builder::new()
        .name("usbtether-control".into())
        .spawn(move || {
            loop {
                let mut s = match listener.accept() {
                    Ok((s, _)) => s,
                    Err(e) => {
                        crate::log!("control socket accept failed: {e}");
                        std::thread::sleep(Duration::from_millis(100));
                        continue;
                    }
                };
                // Bounded in time and size: a stuck or hostile client must not
                // wedge the control thread.
                if s.set_read_timeout(Some(REQUEST_DEADLINE)).is_err()
                    || s.set_write_timeout(Some(REQUEST_DEADLINE)).is_err()
                {
                    continue;
                }
                let allowed = stream_peer_allowed(&s);
                let _ = serve_conn(&mut s, allowed, &ctx);
            }
        })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devices::{ApprovedDevice, DeviceId};
    use crate::gate::Decision;
    use std::fs;
    use std::sync::atomic::{AtomicU32, Ordering};

    static N: AtomicU32 = AtomicU32::new(0);

    fn ctx() -> Ctx {
        let d = std::env::temp_dir().join(format!(
            "usbtether-controltest-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        Ctx {
            gate: Gate::new(),
            store: Store::load(&d.join("devices.json"), unsafe { libc::geteuid() }),
            phone: None,
        }
    }

    fn id(pid: u16) -> DeviceId {
        DeviceId {
            vid: 0x04e8,
            pid,
            serial: Some(format!("S{pid}")),
        }
    }

    fn prompt(c: &mut Ctx, pid: u16, name: &str) -> String {
        match c.gate.evaluate(&id(pid), name, &c.store) {
            Decision::Prompt(r) => r,
            d => panic!("expected Prompt, got {d:?}"),
        }
    }

    fn json(s: &str) -> serde_json::Value {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn status_lists_pending_and_approved() {
        let mut c = ctx();
        c.store
            .add(ApprovedDevice {
                id: id(1),
                name: "Pixel \"q\"".into(),
                approved_at: 42,
            })
            .unwrap();
        let r = prompt(&mut c, 2, "Galaxy");
        c.phone = Some(PhoneInfo {
            ip: "192.168.42.129".into(),
            router: "192.168.42.129".into(),
            ifname: "utun5".into(),
        });
        let v = json(&handle(r#"{"cmd":"status"}"#, &mut c));
        assert_eq!(v["phone"]["ip"], "192.168.42.129");
        assert_eq!(v["phone"]["router"], "192.168.42.129");
        assert_eq!(v["phone"]["ifname"], "utun5");
        let p = &v["pending"][0];
        assert_eq!(p["request_id"], r);
        assert_eq!(p["name"], "Galaxy");
        assert_eq!(p["vid"], 0x04e8);
        assert_eq!(p["pid"], 2);
        assert_eq!(p["serial"], "S2");
        let a = &v["approved"][0];
        assert_eq!(a["name"], "Pixel \"q\"");
        assert_eq!(a["vid"], 0x04e8);
        assert_eq!(a["pid"], 1);
        assert_eq!(a["serial"], "S1");
        assert_eq!(a["approved_at"], 42);
        assert_eq!(v.as_object().unwrap().len(), 3);
        assert_eq!(p.as_object().unwrap().len(), 5);
        assert_eq!(a.as_object().unwrap().len(), 5);

        c.phone = None;
        let v = json(&handle(r#"{"cmd":"status"}"#, &mut c));
        assert!(v["phone"].is_null());
    }

    #[test]
    fn approve_moves_pending_to_approved() {
        let mut c = ctx();
        let r = prompt(&mut c, 1, "Pixel");
        let line = format!(r#"{{"cmd":"approve","request_id":"{r}"}}"#);
        let v = json(&handle(&line, &mut c));
        assert!(v["pending"].as_array().unwrap().is_empty());
        assert_eq!(v["approved"][0]["name"], "Pixel");
        assert!(c.store.is_approved(&id(1)));
    }

    #[test]
    fn decline_clears_pending_without_approving() {
        let mut c = ctx();
        let r = prompt(&mut c, 1, "Pixel");
        let line = format!(r#"{{"cmd":"decline","request_id":"{r}"}}"#);
        let v = json(&handle(&line, &mut c));
        assert!(v["pending"].as_array().unwrap().is_empty());
        assert!(v["approved"].as_array().unwrap().is_empty());
        assert!(!c.store.is_approved(&id(1)));
    }

    #[test]
    fn remove_deletes_approved_entry() {
        let mut c = ctx();
        c.store
            .add(ApprovedDevice {
                id: id(1),
                name: "Pixel".into(),
                approved_at: 1,
            })
            .unwrap();
        let v = json(&handle(
            r#"{"cmd":"remove","vid":1256,"pid":1,"serial":"S1"}"#,
            &mut c,
        ));
        assert!(v["approved"].as_array().unwrap().is_empty());
        assert!(!c.store.is_approved(&id(1)));
    }

    #[test]
    fn approve_with_unknown_request_id_errors_and_keeps_state() {
        let mut c = ctx();
        let r = prompt(&mut c, 1, "Pixel");
        let v = json(&handle(
            r#"{"cmd":"approve","request_id":"0000000000000000"}"#,
            &mut c,
        ));
        assert!(v["error"].is_string());
        assert!(c.store.list().is_empty());
        assert_eq!(c.gate.pending().len(), 1);
        assert_eq!(c.gate.pending()[0].request_id, r);
    }

    #[test]
    fn malformed_json_and_unknown_cmd_return_error_and_change_nothing() {
        let mut c = ctx();
        prompt(&mut c, 1, "Pixel");
        for line in [
            "",
            "not json",
            "{",
            r#"{"cmd":"explode"}"#,
            r#"{"cmd":"approve"}"#,
            r#"{"cmd":"remove","vid":70000,"pid":1}"#,
            r#"{"nocmd":1}"#,
        ] {
            let v = json(&handle(line, &mut c));
            assert!(v["error"].is_string(), "{line}");
            assert_eq!(c.gate.pending().len(), 1);
            assert!(c.store.list().is_empty());
        }
    }

    #[test]
    fn remove_store_failure_is_error() {
        let mut c = ctx();
        c.store
            .add(ApprovedDevice {
                id: id(1),
                name: "Pixel".into(),
                approved_at: 1,
            })
            .unwrap();
        // Make the store's directory unwritable by replacing it with a file.
        // (Skipped when running as root, where permissions do not bite.)
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let d =
            std::env::temp_dir().join(format!("usbtether-controltest-ro-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        let mut s = Store::load(&d.join("devices.json"), unsafe { libc::geteuid() });
        s.add(ApprovedDevice {
            id: id(1),
            name: "x".into(),
            approved_at: 1,
        })
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&d, fs::Permissions::from_mode(0o500)).unwrap();
        c.store = s;
        let v = json(&handle(
            r#"{"cmd":"remove","vid":1256,"pid":1,"serial":"S1"}"#,
            &mut c,
        ));
        fs::set_permissions(&d, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(v["error"].is_string());
    }

    #[test]
    fn read_request_accepts_line_and_rejects_65_kib() {
        let ok = b"{\"cmd\":\"status\"}\n";
        assert_eq!(
            read_request(&ok[..], Duration::from_secs(2)).unwrap(),
            "{\"cmd\":\"status\"}\n"
        );
        let mut big = vec![b'a'; 65 * 1024];
        big.push(b'\n');
        assert!(read_request(&big[..], Duration::from_secs(2)).is_err());
        let big_no_nl = vec![b'a'; 65 * 1024];
        assert!(read_request(&big_no_nl[..], Duration::from_secs(2)).is_err());
    }

    #[test]
    fn slow_drip_request_hits_total_deadline() {
        struct Drip;
        impl Read for Drip {
            fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
                std::thread::sleep(Duration::from_millis(30));
                buf[0] = b'a';
                Ok(1)
            }
        }
        let start = Instant::now();
        let e = read_request(Drip, Duration::from_millis(100)).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn allowed_peer_status_request_gets_status_json() {
        use std::os::unix::net::UnixStream;
        let (mut server, mut client) = UnixStream::pair().unwrap();
        let mut c = ctx();
        let r = prompt(&mut c, 2, "Galaxy");
        let c = Mutex::new(c);
        client.write_all(b"{\"cmd\":\"status\"}\n").unwrap();
        serve_conn(&mut server, true, &c).unwrap();
        drop(server);
        let mut out = String::new();
        client.read_to_string(&mut out).unwrap();
        assert!(out.ends_with('\n'));
        let v = json(out.trim_end());
        assert_eq!(v["pending"][0]["request_id"], r);
        assert!(v["approved"].as_array().unwrap().is_empty());
    }

    #[test]
    fn root_and_admin_allowed_others_not() {
        assert!(peer_allowed(0, |_| false));
        assert!(peer_allowed(501, |_| true));
        assert!(!peer_allowed(501, |_| false));
    }

    #[test]
    fn denied_peer_gets_only_not_allowed_and_request_is_not_read() {
        struct Spy {
            read: bool,
            out: Vec<u8>,
        }
        impl Read for Spy {
            fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                self.read = true;
                Ok(0)
            }
        }
        impl Write for Spy {
            fn write(&mut self, b: &[u8]) -> io::Result<usize> {
                self.out.extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let c = Mutex::new(ctx());
        let mut s = Spy {
            read: false,
            out: vec![],
        };
        serve_conn(&mut s, false, &c).unwrap();
        assert!(!s.read);
        assert_eq!(s.out, b"{\"error\":\"not allowed\"}\n");
    }
}
