//! Starts the approval app in the console user's session when a phone needs
//! approving. The app pulls pending requests over the control socket; nothing
//! is passed on the command line.

use std::io;
use std::os::unix::fs::MetadataExt;
use std::process::{Command, Stdio};

const APP_BUNDLE_ID: &str = "com.philipp.UsbTether";

/// Owner of `/dev/console`: the user at the screen. `None` at the login
/// window (owner is root) or if it cannot be read.
pub fn console_uid() -> Option<u32> {
    let uid = std::fs::metadata("/dev/console").ok()?.uid();
    (uid != 0).then_some(uid)
}

/// Launch only for a real (non-root) console user, only with something
/// pending, and only on news: a fresh prompt or a different console user.
pub fn should_launch(
    prev: Option<u32>,
    now: Option<u32>,
    newly_prompted: bool,
    pending_nonempty: bool,
) -> bool {
    pending_nonempty && matches!(now, Some(uid) if uid != 0) && (newly_prompted || prev != now)
}

pub fn launch_app(uid: u32) -> io::Result<()> {
    let status = Command::new("/bin/launchctl")
        .arg("asuser")
        .arg(uid.to_string())
        .arg("/usr/bin/open")
        .arg("-b")
        .arg(APP_BUNDLE_ID)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("launchctl exited with {status}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_launches_for_login_window_or_root() {
        assert!(!should_launch(None, Some(0), true, true));
        assert!(!should_launch(Some(501), None, true, true));
    }

    #[test]
    fn launches_when_newly_prompted() {
        assert!(should_launch(Some(501), Some(501), true, true));
        assert!(!should_launch(Some(501), Some(501), true, false));
    }

    #[test]
    fn launches_again_at_login() {
        assert!(should_launch(None, Some(501), false, true));
        assert!(should_launch(Some(502), Some(501), false, true));
        assert!(!should_launch(Some(501), Some(501), false, true));
        assert!(!should_launch(None, Some(501), false, false));
    }
}
