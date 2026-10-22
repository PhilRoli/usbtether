//! Approval gate: the authorization decision point. A device connects only if
//! the store already approves it; anything else gets one prompt per plug-in
//! event and waits for an explicit approve/decline by request id.

// consumed by later tasks (control/main); remove once wired
#![allow(dead_code)]

use std::collections::HashSet;
use std::io;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::devices::{ApprovedDevice, DeviceId, Store};

pub type RequestId = String;

#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Connect,
    Prompt(RequestId),
    Wait,
}

#[derive(Clone, Debug, Serialize)]
pub struct PendingInfo {
    pub request_id: RequestId,
    pub name: String,
    pub id: DeviceId,
}

#[derive(Debug)]
pub enum GateError {
    UnknownRequest,
    Store(io::Error),
}

#[derive(Default)]
pub struct Gate {
    pending: Vec<PendingInfo>,
    declined: HashSet<DeviceId>,
}

fn new_request_id() -> RequestId {
    let (a, b) = unsafe { (libc::arc4random(), libc::arc4random()) };
    format!("{a:08x}{b:08x}")
}

impl Gate {
    pub fn new() -> Gate {
        Gate::default()
    }

    pub fn evaluate(&mut self, id: &DeviceId, name: &str, store: &Store) -> Decision {
        if store.is_approved(id) {
            return Decision::Connect;
        }
        if self.declined.contains(id) || self.pending.iter().any(|p| p.id == *id) {
            return Decision::Wait;
        }
        let mut request_id = new_request_id();
        while self.pending.iter().any(|p| p.request_id == request_id) {
            request_id = new_request_id();
        }
        self.pending.push(PendingInfo {
            request_id: request_id.clone(),
            name: name.to_string(),
            id: id.clone(),
        });
        Decision::Prompt(request_id)
    }

    pub fn pending(&self) -> Vec<PendingInfo> {
        self.pending.clone()
    }

    pub fn approve(&mut self, request_id: &str, store: &mut Store) -> Result<(), GateError> {
        let pos = self
            .pending
            .iter()
            .position(|p| p.request_id == request_id)
            .ok_or(GateError::UnknownRequest)?;
        let entry = &self.pending[pos];
        let approved_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        store
            .add(ApprovedDevice {
                id: entry.id.clone(),
                name: entry.name.clone(),
                approved_at,
            })
            .map_err(GateError::Store)?;
        self.pending.remove(pos);
        Ok(())
    }

    pub fn decline(&mut self, request_id: &str) -> Result<(), GateError> {
        let pos = self
            .pending
            .iter()
            .position(|p| p.request_id == request_id)
            .ok_or(GateError::UnknownRequest)?;
        let entry = self.pending.remove(pos);
        self.declined.insert(entry.id);
        Ok(())
    }

    pub fn device_gone(&mut self, present: &[DeviceId]) {
        self.pending.retain(|p| present.contains(&p.id));
        self.declined.retain(|d| present.contains(d));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    static N: AtomicU32 = AtomicU32::new(0);

    fn store() -> Store {
        let d: PathBuf = std::env::temp_dir().join(format!(
            "usbtether-gatetest-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        Store::load(&d.join("devices.json"), unsafe { libc::geteuid() })
    }

    fn id(pid: u16) -> DeviceId {
        DeviceId {
            vid: 0x04e8,
            pid,
            serial: Some(format!("S{pid}")),
        }
    }

    fn approved(i: DeviceId) -> ApprovedDevice {
        ApprovedDevice {
            id: i,
            name: "n".into(),
            approved_at: 1,
        }
    }

    fn prompt(d: Decision) -> RequestId {
        match d {
            Decision::Prompt(r) => r,
            other => panic!("expected Prompt, got {other:?}"),
        }
    }

    #[test]
    fn approved_device_connects() {
        let mut s = store();
        s.add(approved(id(1))).unwrap();
        let mut g = Gate::new();
        assert_eq!(g.evaluate(&id(1), "Pixel", &s), Decision::Connect);
        assert!(g.pending().is_empty());
    }

    #[test]
    fn unknown_device_prompts_once_then_waits() {
        let s = store();
        let mut g = Gate::new();
        let r = prompt(g.evaluate(&id(1), "Pixel", &s));
        assert_eq!(r.len(), 16);
        assert!(r.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')));
        assert_eq!(g.evaluate(&id(1), "Pixel", &s), Decision::Wait);
        let p = g.pending();
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].request_id, r);
        assert_eq!(p[0].name, "Pixel");
        assert_eq!(p[0].id, id(1));
    }

    #[test]
    fn two_devices_only_approved_one_connects() {
        let mut s = store();
        s.add(approved(id(1))).unwrap();
        let mut g = Gate::new();
        assert_eq!(g.evaluate(&id(1), "A", &s), Decision::Connect);
        let rb = prompt(g.evaluate(&id(2), "B", &s));
        assert_eq!(g.pending().len(), 1);
        assert_eq!(g.pending()[0].request_id, rb);
        // two unapproved devices each get their own request
        let rc = prompt(g.evaluate(&id(3), "C", &s));
        assert_ne!(rb, rc);
        assert_eq!(g.pending().len(), 2);
    }

    #[test]
    fn approve_adds_to_store_and_connects() {
        let mut s = store();
        let mut g = Gate::new();
        let r = prompt(g.evaluate(&id(1), "Pixel", &s));
        g.approve(&r, &mut s).unwrap();
        assert_eq!(g.evaluate(&id(1), "Pixel", &s), Decision::Connect);
        assert!(s.is_approved(&id(1)));
        assert_eq!(s.list()[0].name, "Pixel");
        assert!(g.pending().is_empty());
    }

    #[test]
    fn approve_unknown_or_stale_request_is_error_and_changes_nothing() {
        let mut s = store();
        let mut g = Gate::new();
        let r = prompt(g.evaluate(&id(1), "Pixel", &s));
        assert!(matches!(
            g.approve("0000000000000000", &mut s),
            Err(GateError::UnknownRequest)
        ));
        assert!(s.list().is_empty());
        g.approve(&r, &mut s).unwrap();
        assert!(matches!(
            g.approve(&r, &mut s),
            Err(GateError::UnknownRequest)
        ));
        assert_eq!(s.list().len(), 1);

        // a declined device's request id cannot be approved
        let r2 = prompt(g.evaluate(&id(2), "B", &s));
        g.decline(&r2).unwrap();
        assert!(matches!(
            g.approve(&r2, &mut s),
            Err(GateError::UnknownRequest)
        ));
        assert!(!s.is_approved(&id(2)));
    }

    #[test]
    fn decline_suppresses_until_unplugged() {
        let s = store();
        let mut g = Gate::new();
        let r = prompt(g.evaluate(&id(1), "Pixel", &s));
        g.decline(&r).unwrap();
        assert!(g.pending().is_empty());
        assert_eq!(g.evaluate(&id(1), "Pixel", &s), Decision::Wait);
        g.device_gone(&[id(1)]);
        assert_eq!(g.evaluate(&id(1), "Pixel", &s), Decision::Wait);
        g.device_gone(&[]);
        let r2 = prompt(g.evaluate(&id(1), "Pixel", &s));
        assert_ne!(r, r2);
    }

    #[test]
    fn device_gone_drops_pending() {
        let s = store();
        let mut g = Gate::new();
        prompt(g.evaluate(&id(1), "A", &s));
        prompt(g.evaluate(&id(2), "B", &s));
        g.device_gone(&[id(2)]);
        let p = g.pending();
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].id, id(2));
        g.device_gone(&[]);
        assert!(g.pending().is_empty());
    }
}
