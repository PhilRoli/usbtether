//! Finds RNDIS tethering candidates from enumeration data alone.

// consumed by later tasks (gate/main); remove once wired
#![allow(dead_code)]

use nusb::MaybeFuture;

use crate::devices::DeviceId;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IfaceDesc {
    pub number: u8,
    pub class: u8,
    pub subclass: u8,
    pub protocol: u8,
}

pub struct Candidate {
    pub id: DeviceId,
    pub name: String,
    pub info: nusb::DeviceInfo,
}

/// (control interface number, data interface number) iff an E0/01/03 control
/// interface and a CDC data (class 0x0A) interface both exist.
pub fn rndis_interfaces(ifaces: &[IfaceDesc]) -> Option<(u8, u8)> {
    let control = ifaces
        .iter()
        .find(|i| i.class == 0xE0 && i.subclass == 0x01 && i.protocol == 0x03)?;
    let data = ifaces.iter().find(|i| i.class == 0x0A)?;
    Some((control.number, data.number))
}

pub fn display_name(
    vid: u16,
    pid: u16,
    manufacturer: Option<&str>,
    product: Option<&str>,
) -> String {
    let parts: Vec<&str> = [manufacturer, product].into_iter().flatten().collect();
    if parts.is_empty() {
        format!("USB device {vid:04x}:{pid:04x}")
    } else {
        parts.join(" ")
    }
}

pub fn scan() -> Vec<Candidate> {
    // SECURITY: discovery must never open or claim a device. It uses only
    // enumeration data from `list_devices`; never call `DeviceInfo::open`.
    let Ok(devices) = nusb::list_devices().wait() else {
        return Vec::new();
    };
    devices
        .filter_map(|info| {
            let ifaces: Vec<IfaceDesc> = info
                .interfaces()
                .map(|i| IfaceDesc {
                    number: i.interface_number(),
                    class: i.class(),
                    subclass: i.subclass(),
                    protocol: i.protocol(),
                })
                .collect();
            rndis_interfaces(&ifaces)?;
            let (vid, pid) = (info.vendor_id(), info.product_id());
            Some(Candidate {
                id: DeviceId {
                    vid,
                    pid,
                    serial: info.serial_number().map(str::to_owned),
                },
                name: display_name(vid, pid, info.manufacturer_string(), info.product_string()),
                info,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn i(number: u8, class: u8, subclass: u8, protocol: u8) -> IfaceDesc {
        IfaceDesc {
            number,
            class,
            subclass,
            protocol,
        }
    }

    #[test]
    fn matches_the_samsung_layout() {
        let ifaces = [i(0, 0xE0, 1, 3), i(1, 0x0A, 0, 0), i(2, 0xFF, 0x42, 1)];
        assert_eq!(rndis_interfaces(&ifaces), Some((0, 1)));
    }

    #[test]
    fn rejects_missing_data_interface() {
        assert_eq!(
            rndis_interfaces(&[i(0, 0xE0, 1, 3), i(2, 0xFF, 0x42, 1)]),
            None
        );
    }

    #[test]
    fn rejects_cdc_acm_variant() {
        assert_eq!(
            rndis_interfaces(&[i(0, 0x02, 0x02, 0xFF), i(1, 0x0A, 0, 0)]),
            None
        );
    }

    #[test]
    fn rejects_adb_only_device() {
        assert_eq!(rndis_interfaces(&[i(0, 0xFF, 0x42, 1)]), None);
    }

    #[test]
    fn name_falls_back_to_vid_pid() {
        assert_eq!(
            display_name(0x04e8, 0x6860, None, None),
            "USB device 04e8:6860"
        );
        assert_eq!(
            display_name(1, 2, Some("SAMSUNG"), Some("SAMSUNG_Android")),
            "SAMSUNG SAMSUNG_Android"
        );
        assert_eq!(display_name(1, 2, None, Some("Phone")), "Phone");
        assert_eq!(display_name(1, 2, Some("ACME"), None), "ACME");
    }

    /// Manual check (Samsung plugged in):
    /// `cargo test discovery:: -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn manual_print_scan() {
        for c in scan() {
            println!("{} {:?}", c.name, c.id);
        }
    }
}
