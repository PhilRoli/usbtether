import Foundation

/// Pure text formatting used by the views.
public enum Presentation {
    public static func vidPid(vid: Int, pid: Int) -> String {
        String(format: "%04x:%04x", vid, pid)
    }

    public static func statusLine(_ status: DaemonStatus?) -> String {
        guard let link = status?.phone else { return "Not connected" }
        return "Connected via \(link.ip)"
    }

    /// Shown only when approval would cover every device with the same USB ID.
    public static func weakIdNote(for phone: PendingPhone) -> String? {
        guard phone.serial == nil else { return nil }
        return "This phone does not report a serial number, so approval covers every device with this USB ID."
    }

    public static func serialText(_ serial: String?) -> String {
        serial ?? "no serial"
    }

    public static func approvalDate(_ epochSeconds: Int, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }
}
