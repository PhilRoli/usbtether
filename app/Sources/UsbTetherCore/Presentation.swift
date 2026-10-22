import CoreServices
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
        guard displaySerial(phone.serial) == nil else { return nil }
        return "This phone does not report a serial number, so approval covers every device with this USB ID."
    }

    public static func serialText(_ serial: String?) -> String {
        displaySerial(serial) ?? "no serial"
    }

    /// The serial as shown on screen, cleaned like the daemon cleans device names (it comes
    /// from the device): control and bidi/format characters stripped, whitespace collapsed,
    /// at most 64 characters. Nil if nothing printable remains. The raw serial is still what
    /// identifies the phone.
    public static func displaySerial(_ serial: String?) -> String? {
        guard let serial else { return nil }
        var cleaned = String.UnicodeScalarView()
        for scalar in serial.unicodeScalars {
            if scalar.properties.isWhitespace {
                cleaned.append(" ")
            } else if scalar.properties.generalCategory != .control && !invisible(scalar) {
                cleaned.append(scalar)
            }
        }
        let collapsed = String(cleaned).split(separator: " ").joined(separator: " ")
        let capped = String(String.UnicodeScalarView(collapsed.unicodeScalars.prefix(maxSerialLength)))
            .trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }

    private static let maxSerialLength = 64

    /// Same set the daemon strips from names (discovery.rs `sanitize`).
    private static func invisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x061C, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064,
             0x2066...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
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

/// `isSystemQuit`: the app is quitting because the user logs out, restarts or shuts down.
/// That is not a "Not now": the phone must be asked about again at the next login.
public func closeAction(displayedPrompt: PendingPhone?, isSystemQuit: Bool) -> CloseAction {
    guard let phone = displayedPrompt, !isSystemQuit else { return .quit }
    return .declineThenQuit(phone)
}

/// True for the `kAEQuitReason` values AppKit sends with a quit at logout, restart or
/// shutdown. Nil (no reason given) is an ordinary quit.
public func isSystemQuitReason(_ reason: UInt32?) -> Bool {
    guard let reason else { return false }
    return [kAELogOut, kAEReallyLogOut, kAERestart, kAEShowRestartDialog, kAEShutDown,
            kAEShowShutdownDialog].contains(reason)
}
