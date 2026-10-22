import Foundation

/// Pure text formatting used by the views.
public enum Presentation {
    public static func vidPid(vid: Int, pid: Int) -> String {
        "\(hex4(vid)):\(hex4(pid))"
    }

    /// Four lowercase hex digits; "????" for values a USB id cannot hold.
    private static func hex4(_ value: Int) -> String {
        guard (0...0xffff).contains(value) else { return "????" }
        return String(format: "%04x", value)
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

/// What to do when the user closes the window or quits.
public enum CloseAction: Equatable, Sendable {
    case quit
    /// Treat the close as "Not now" for the phone that was on screen, then quit.
    case declineThenQuit(PendingPhone)
}

public func closeAction(displayedPrompt: PendingPhone?) -> CloseAction {
    guard let phone = displayedPrompt else { return .quit }
    return .declineThenQuit(phone)
}
