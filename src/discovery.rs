//! Finds RNDIS tethering candidates from enumeration data alone.

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
///
/// Pairing is anchored on the control interface (duplicate controls resolve
/// to the first one): prefer the data interface numbered control + 1,
/// otherwise the first data interface numbered above the control. A data
/// interface below the control is never chosen.
pub fn rndis_interfaces(ifaces: &[IfaceDesc]) -> Option<(u8, u8)> {
    let control = ifaces
        .iter()
        .find(|i| i.class == 0xE0 && i.subclass == 0x01 && i.protocol == 0x03)?;
    let mut data = ifaces
        .iter()
        .filter(|i| i.class == 0x0A && i.number > control.number);
    let next = control.number.checked_add(1);
    let chosen = ifaces
        .iter()
        .find(|i| i.class == 0x0A && Some(i.number) == next)
        .or_else(|| data.next())?;
    Some((control.number, chosen.number))
}

const MAX_NAME_PART: usize = 64;

/// Device-controlled strings end up in logs and an approval dialog: strip
/// control and bidi/format characters, collapse whitespace, cap the length.
/// Returns None if nothing printable remains.
fn sanitize(s: Option<&str>) -> Option<String> {
    let cleaned: String = s?
        .chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .filter(|&c| {
            !(c.is_control()
                || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}'
                    | '\u{2066}'..='\u{2069}' | '\u{FEFF}'))
        })
        .collect();
    let collapsed = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    let capped: String = collapsed.chars().take(MAX_NAME_PART).collect();
    let capped = capped.trim().to_owned();
    (!capped.is_empty()).then_some(capped)
}

pub fn display_name(
    vid: u16,
    pid: u16,
    manufacturer: Option<&str>,
    product: Option<&str>,
) -> String {
    let parts: Vec<String> = [sanitize(manufacturer), sanitize(product)]
        .into_iter()
        .flatten()
        .collect();
    if parts.is_empty() {
        format!("USB device {vid:04x}:{pid:04x}")
    } else {
        parts.join(" ")
    }
}

pub fn scan() -> Vec<Candidate> {
    // SECURITY: discovery must never open or claim a device. It uses only
    // enumeration data from `list_devices`; never call `DeviceInfo::open`.
    let devices = match nusb::list_devices().wait() {
        Ok(d) => d,
        Err(e) => {
            crate::log!("warning: could not enumerate USB devices: {e}");
            return Vec::new();
        }
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

    #[test]
    fn decoy_data_before_control_is_not_chosen() {
        let ifaces = [i(0, 0x0A, 0, 0), i(1, 0xE0, 1, 3)];
        assert_eq!(rndis_interfaces(&ifaces), None);
        let ifaces = [i(0, 0x0A, 0, 0), i(1, 0xE0, 1, 3), i(2, 0x0A, 0, 0)];
        assert_eq!(rndis_interfaces(&ifaces), Some((1, 2)));
    }

    #[test]
    fn adjacent_data_preferred_over_later() {
        let ifaces = [i(0, 0xE0, 1, 3), i(5, 0x0A, 0, 0), i(1, 0x0A, 0, 0)];
        assert_eq!(rndis_interfaces(&ifaces), Some((0, 1)));
    }

    #[test]
    fn non_adjacent_later_data_accepted() {
        let ifaces = [i(0, 0xE0, 1, 3), i(3, 0x0A, 0, 0)];
        assert_eq!(rndis_interfaces(&ifaces), Some((0, 3)));
    }

    #[test]
    fn empty_slice_is_none() {
        assert_eq!(rndis_interfaces(&[]), None);
    }

    #[test]
    fn duplicate_controls_resolve_to_first() {
        let ifaces = [
            i(0, 0xE0, 1, 3),
            i(1, 0x0A, 0, 0),
            i(2, 0xE0, 1, 3),
            i(3, 0x0A, 0, 0),
        ];
        assert_eq!(rndis_interfaces(&ifaces), Some((0, 1)));
    }

    #[test]
    fn names_are_sanitised() {
        assert_eq!(
            display_name(1, 2, Some("A\nB\x1b[31m"), Some("x\u{202E}evil\u{200B}\ty")),
            "A B[31m xevil y"
        );
        let long = "a".repeat(200);
        assert_eq!(display_name(1, 2, Some(&long), None), "a".repeat(64));
        assert_eq!(
            display_name(0x04e8, 0x6864, Some("   "), Some("")),
            "USB device 04e8:6864"
        );
        assert_eq!(
            display_name(0x04e8, 0x6864, Some("SAMSUNG"), Some("SAMSUNG_Android")),
            "SAMSUNG SAMSUNG_Android"
        );
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
