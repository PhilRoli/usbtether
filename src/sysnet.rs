//! macOS network configuration for the tether, and the guarantees that it is
//! undone: on normal exit (Drop), on Ctrl+C, and — via a detached guard
//! process — even if this process is killed outright.

use std::io::{self, Write};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

use std::net::Ipv4Addr;

use crate::packet::Lease;

const SVC: &str = "State:/Network/Service/usbtether";
const SPLIT_DEFAULT: [&str; 2] = ["0.0.0.0/1", "128.0.0.0/1"];

fn run(cmd: &str, args: &[&str]) -> io::Result<()> {
    let out = Command::new(cmd).args(args).stdin(Stdio::null()).output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "{cmd} {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(())
}

/// Run an scutil script. scutil exits 0 even when a command fails and reports
/// the failure on stdout instead ("Permission denied"); the commands used here
/// print nothing on success, so any output at all is an error.
fn scutil(script: &str) -> io::Result<()> {
    let mut child = Command::new("/usr/sbin/scutil")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    // Dropping stdin at the end of this statement gives scutil its EOF.
    child.stdin.take().unwrap().write_all(script.as_bytes())?;
    let out = child.wait_with_output()?;
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let said = said.trim();
    if !out.status.success() || !said.is_empty() {
        return Err(io::Error::other(format!("scutil: {said} ({})", out.status)));
    }
    Ok(())
}

/// Drop our DNS/service registration. Safe to call when none exists.
pub fn remove_dns() {
    let _ = scutil(&format!("remove {SVC}/IPv4\nremove {SVC}/DNS\n"));
}

/// Watch this process from a detached shell and remove the DNS registration
/// once it is gone, however it died. Routes need no guard: they live on the
/// utun interface, which the kernel destroys with the process.
pub fn spawn_guard() -> io::Result<()> {
    let pid = std::process::id();
    // If a new usbtetherd is already up by the time we notice the old one is
    // gone, the DNS entry is the new one's: leave it.
    let script = format!(
        "while kill -0 {pid} 2>/dev/null; do sleep 1; done; \
         /usr/bin/pgrep -qx usbtetherd || \
         printf 'remove {SVC}/IPv4\\nremove {SVC}/DNS\\n' | /usr/sbin/scutil"
    );
    unsafe {
        Command::new("/bin/sh")
            .arg("-c")
            .arg(script)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .pre_exec(|| {
                libc::setsid();
                Ok(())
            })
            .spawn()?;
    }
    Ok(())
}

/// The tether's addresses, routes and DNS, removed again on drop.
pub struct NetConfig {
    ifname: String,
}

impl NetConfig {
    /// `test`: only sockets bound to the interface use it (scoped default
    /// route, no DNS change), so the rest of the Mac keeps its connection.
    pub fn apply(ifname: &str, lease: &Lease, mtu: u32, test: bool) -> io::Result<NetConfig> {
        // Constructed first so a failure part-way through still cleans up.
        let cfg = NetConfig {
            ifname: ifname.to_string(),
        };
        let (ip, router) = (lease.ip.to_string(), lease.router.to_string());

        // Point-to-point to the phone: everything we send goes to it anyway.
        run(
            "/sbin/ifconfig",
            &[
                ifname,
                "inet",
                &ip,
                &router,
                "netmask",
                "255.255.255.255",
                "mtu",
                &mtu.to_string(),
                "up",
            ],
        )?;
        if test {
            run(
                "/sbin/route",
                &["-q", "-n", "add", "-ifscope", ifname, "default", &router],
            )?;
            return Ok(cfg);
        }

        // Two /1 routes beat the existing default without replacing it, so
        // Wi-Fi's own route comes back untouched the moment we go away.
        for net in SPLIT_DEFAULT {
            run(
                "/sbin/route",
                &["-q", "-n", "add", "-net", net, "-interface", ifname],
            )?;
        }

        // Register with configd so DNS works (and apps see a network) even
        // with Wi-Fi off. The phone runs a DNS proxy at its own address.
        let dns = lease
            .dns
            .iter()
            .map(|d| d.to_string())
            .collect::<Vec<_>>()
            .join(" ");
        scutil(&format!(
            "d.init\n\
             d.add Addresses * {ip}\n\
             d.add DestAddresses * {router}\n\
             d.add InterfaceName {ifname}\n\
             d.add Router {router}\n\
             set {SVC}/IPv4\n\
             d.init\n\
             d.add ServerAddresses * {dns}\n\
             d.add SupplementalMatchDomains * \"\"\n\
             set {SVC}/DNS\n"
        ))?;
        Ok(cfg)
    }
}

impl Drop for NetConfig {
    fn drop(&mut self) {
        remove_dns();
        for net in SPLIT_DEFAULT {
            let _ = run(
                "/sbin/route",
                &[
                    "-q",
                    "-n",
                    "delete",
                    "-net",
                    net,
                    "-interface",
                    &self.ifname,
                ],
            );
        }
    }
}

/// Every IPv4 address currently configured on any local interface.
pub fn local_ipv4_addrs() -> io::Result<Vec<Ipv4Addr>> {
    let mut out = Vec::new();
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut list) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut cur = list;
    while !cur.is_null() {
        // SAFETY: `cur` is a node of the list getifaddrs returned, valid until freeifaddrs.
        let ifa = unsafe { &*cur };
        if !ifa.ifa_addr.is_null() && unsafe { (*ifa.ifa_addr).sa_family } as i32 == libc::AF_INET {
            let sin = unsafe { &*(ifa.ifa_addr as *const libc::sockaddr_in) };
            out.push(Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr)));
        }
        cur = ifa.ifa_next;
    }
    unsafe { libc::freeifaddrs(list) };
    Ok(out)
}

/// True if the phone's lease would hand us, or point us at, an address this
/// Mac already uses. Mere subnet overlap is fine: the tether only installs /1
/// routes and a /32 host route.
pub fn lease_collides(lease: &Lease, local: &[Ipv4Addr]) -> bool {
    local.contains(&lease.ip) || local.contains(&lease.router)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    fn lease(ip: [u8; 4], router: [u8; 4]) -> Lease {
        Lease {
            ip: Ipv4Addr::from(ip),
            mask: Ipv4Addr::new(255, 255, 255, 0),
            router: Ipv4Addr::from(router),
            dns: vec![],
            lease_secs: 3600,
            server: Ipv4Addr::from(router),
            server_mac: [0; 6],
        }
    }

    #[test]
    fn lease_colliding_with_local_address_is_rejected() {
        let local = [Ipv4Addr::new(192, 168, 1, 10)];
        assert!(lease_collides(
            &lease([192, 168, 1, 10], [192, 168, 42, 129]),
            &local
        ));
        assert!(lease_collides(
            &lease([192, 168, 42, 5], [192, 168, 1, 10]),
            &local
        ));
    }

    #[test]
    fn same_subnet_different_host_is_allowed() {
        let local = [Ipv4Addr::new(192, 168, 1, 10)];
        assert!(!lease_collides(
            &lease([192, 168, 1, 77], [192, 168, 1, 1]),
            &local
        ));
    }

    #[test]
    fn local_addrs_include_loopback() {
        assert!(
            local_ipv4_addrs()
                .unwrap()
                .contains(&Ipv4Addr::new(127, 0, 0, 1))
        );
    }

    #[test]
    fn empty_local_list_never_collides() {
        assert!(!lease_collides(&lease([10, 0, 0, 2], [10, 0, 0, 1]), &[]));
    }

    #[test]
    fn scutil_reports_a_failed_command_despite_exit_status_0() {
        let e = scutil("no_such_command\n").unwrap_err();
        assert!(e.to_string().contains("no_such_command"), "{e}");
        scutil("d.init\nd.add Probe 1\n").unwrap();
    }
}
