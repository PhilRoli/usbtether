//! Approved-device allowlist, persisted as JSON. Fails closed: any problem
//! loading the file (missing, corrupt, oversized, too many entries, wrong
//! owner, not a regular file) yields an empty store, never "approve all".

// consumed by later tasks (gate/control/main); remove once wired
#![allow(dead_code)]

use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const STORE_PATH: &str = "/Library/Application Support/usbtether/devices.json";

const MAX_FILE_BYTES: u64 = 64 * 1024;
const MAX_ENTRIES: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DeviceId {
    pub vid: u16,
    pub pid: u16,
    pub serial: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct ApprovedDevice {
    pub id: DeviceId,
    pub name: String,
    /// Unix seconds.
    pub approved_at: u64,
}

pub struct Store {
    path: PathBuf,
    devices: Vec<ApprovedDevice>,
}

fn read_devices(path: &Path, owner_uid: u32) -> Option<Vec<ApprovedDevice>> {
    // O_NOFOLLOW: a symlink at the path fails to open; fstat the opened fd so
    // the checks apply to the file actually read.
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.uid() != owner_uid || meta.len() > MAX_FILE_BYTES {
        return None;
    }
    let mut buf = Vec::new();
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut buf).ok()?;
    if buf.len() as u64 > MAX_FILE_BYTES {
        return None;
    }
    let devices: Vec<ApprovedDevice> = serde_json::from_slice(&buf).ok()?;
    (devices.len() <= MAX_ENTRIES).then_some(devices)
}

impl Store {
    pub fn load(path: &Path, owner_uid: u32) -> Store {
        Store {
            path: path.to_path_buf(),
            devices: read_devices(path, owner_uid).unwrap_or_default(),
        }
    }

    pub fn is_approved(&self, id: &DeviceId) -> bool {
        self.devices.iter().any(|d| d.id == *id)
    }

    pub fn add(&mut self, dev: ApprovedDevice) -> io::Result<()> {
        let mut next = self.devices.clone();
        if let Some(existing) = next.iter_mut().find(|d| d.id == dev.id) {
            existing.name = dev.name;
        } else if next.len() >= MAX_ENTRIES {
            return Err(io::Error::other("approved-device limit reached"));
        } else {
            next.push(dev);
        }
        self.save(&next)?;
        self.devices = next;
        Ok(())
    }

    pub fn remove(&mut self, id: &DeviceId) -> io::Result<bool> {
        let next: Vec<_> = self
            .devices
            .iter()
            .filter(|d| d.id != *id)
            .cloned()
            .collect();
        if next.len() == self.devices.len() {
            return Ok(false);
        }
        self.save(&next)?;
        self.devices = next;
        Ok(true)
    }

    pub fn list(&self) -> &[ApprovedDevice] {
        &self.devices
    }

    fn save(&self, devices: &[ApprovedDevice]) -> io::Result<()> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut tmp = self.path.clone().into_os_string();
        tmp.push(".tmp");
        let tmp = PathBuf::from(tmp);
        let _ = fs::remove_file(&tmp);
        let json = serde_json::to_vec_pretty(devices).map_err(io::Error::other)?;
        let result = (|| {
            let mut f = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&tmp)?;
            f.write_all(&json)?;
            f.sync_all()?;
            fs::rename(&tmp, &self.path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU32, Ordering};

    static N: AtomicU32 = AtomicU32::new(0);

    fn tmpdir() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "usbtether-devtest-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn uid() -> u32 {
        unsafe { libc::geteuid() }
    }

    fn id(vid: u16, pid: u16, serial: Option<&str>) -> DeviceId {
        DeviceId {
            vid,
            pid,
            serial: serial.map(String::from),
        }
    }

    fn dev(i: DeviceId, name: &str) -> ApprovedDevice {
        ApprovedDevice {
            id: i,
            name: name.into(),
            approved_at: 1_700_000_000,
        }
    }

    #[test]
    fn add_then_reload_roundtrips() {
        let p = tmpdir().join("devices.json");
        let mut s = Store::load(&p, uid());
        s.add(dev(id(1, 2, Some("A")), "Pixel")).unwrap();
        let s2 = Store::load(&p, uid());
        assert!(s2.is_approved(&id(1, 2, Some("A"))));
        assert_eq!(s2.list().len(), 1);
        assert_eq!(s2.list()[0].name, "Pixel");
        assert_eq!(s2.list()[0].approved_at, 1_700_000_000);
    }

    #[test]
    fn serial_must_match_exactly() {
        let p = tmpdir().join("devices.json");
        let mut s = Store::load(&p, uid());
        s.add(dev(id(1, 2, Some("A")), "a")).unwrap();
        assert!(s.is_approved(&id(1, 2, Some("A"))));
        assert!(!s.is_approved(&id(1, 2, Some("B"))));
        assert!(!s.is_approved(&id(1, 2, None)));

        let p = tmpdir().join("devices.json");
        let mut s = Store::load(&p, uid());
        s.add(dev(id(1, 2, None), "n")).unwrap();
        assert!(s.is_approved(&id(1, 2, None)));
        assert!(!s.is_approved(&id(1, 2, Some("A"))));
    }

    #[test]
    fn remove_reports_whether_present() {
        let p = tmpdir().join("devices.json");
        let mut s = Store::load(&p, uid());
        let i = id(1, 2, Some("A"));
        s.add(dev(i.clone(), "a")).unwrap();
        assert!(s.remove(&i).unwrap());
        assert!(!s.remove(&i).unwrap());
        assert!(!Store::load(&p, uid()).is_approved(&i));
    }

    #[test]
    fn add_is_idempotent_and_updates_name() {
        let p = tmpdir().join("devices.json");
        let mut s = Store::load(&p, uid());
        s.add(dev(id(1, 2, Some("A")), "old")).unwrap();
        s.add(dev(id(1, 2, Some("A")), "new")).unwrap();
        assert_eq!(s.list().len(), 1);
        assert_eq!(s.list()[0].name, "new");
    }

    fn entries_json(n: usize) -> String {
        let v: Vec<ApprovedDevice> = (0..n)
            .map(|i| dev(id(1, i as u16, Some("S")), "x"))
            .collect();
        serde_json::to_string(&v).unwrap()
    }

    #[test]
    fn corrupt_or_missing_file_is_empty() {
        let d = tmpdir();
        assert!(
            Store::load(&d.join("missing.json"), uid())
                .list()
                .is_empty()
        );
        for (n, body) in [
            ("a", "not json".to_string()),
            ("b", "{}".to_string()),
            ("c", entries_json(65)),
        ] {
            let p = d.join(n);
            fs::write(&p, body).unwrap();
            assert!(Store::load(&p, uid()).list().is_empty(), "{n}");
        }
        // sanity: 64 entries is accepted
        let p = d.join("ok");
        fs::write(&p, entries_json(64)).unwrap();
        assert_eq!(Store::load(&p, uid()).list().len(), 64);
    }

    #[test]
    fn oversized_file_is_empty() {
        let p = tmpdir().join("big.json");
        let pad = " ".repeat(65 * 1024);
        fs::write(&p, format!("[{pad}]")).unwrap();
        assert!(Store::load(&p, uid()).list().is_empty());
    }

    #[test]
    fn file_with_wrong_owner_is_empty() {
        let p = tmpdir().join("devices.json");
        let mut s = Store::load(&p, uid());
        s.add(dev(id(1, 2, Some("A")), "a")).unwrap();
        assert!(Store::load(&p, uid().wrapping_add(1)).list().is_empty());
        assert_eq!(Store::load(&p, uid()).list().len(), 1);
    }

    #[test]
    fn symlink_is_rejected() {
        let d = tmpdir();
        let real = d.join("real.json");
        fs::write(&real, entries_json(1)).unwrap();
        let link = d.join("link.json");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(Store::load(&link, uid()).list().is_empty());
        assert_eq!(Store::load(&real, uid()).list().len(), 1);
    }

    #[test]
    fn saved_file_is_mode_600_and_atomic() {
        let d = tmpdir();
        let p = d.join("devices.json");
        let mut s = Store::load(&p, uid());
        s.add(dev(id(1, 2, Some("A")), "a")).unwrap();
        let mode = fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let names: Vec<_> = fs::read_dir(&d)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["devices.json".to_string()]);
    }
}
