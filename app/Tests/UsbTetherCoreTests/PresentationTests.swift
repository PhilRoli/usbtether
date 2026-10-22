import CoreServices
import XCTest
@testable import UsbTetherCore

final class PresentationTests: XCTestCase {
    func testVidPidFormatting() {
        XCTAssertEqual(Presentation.vidPid(vid: 0x04e8, pid: 0x6864), "04e8:6864")
        XCTAssertEqual(Presentation.vidPid(vid: 0, pid: 0), "0000:0000")
        XCTAssertEqual(Presentation.vidPid(vid: 0x18d1, pid: 0x4ee1), "18d1:4ee1")
    }

    func testStatusLineConnectedAndDisconnected() {
        let link = PhoneLink(ip: "192.168.42.129", router: "192.168.42.129", ifname: "en7")
        XCTAssertEqual(
            Presentation.statusLine(DaemonStatus(phone: link, pending: [], approved: [])),
            "Connected via 192.168.42.129")
        XCTAssertEqual(Presentation.statusLine(status()), "Not connected")
        XCTAssertEqual(Presentation.statusLine(nil), "Not connected")
    }

    func testWeakIdNoteOnlyWhenSerialMissing() {
        let weak = PendingPhone(requestID: "w", name: "X", vid: 1, pid: 2, serial: nil)
        XCTAssertEqual(
            Presentation.weakIdNote(for: weak),
            "This phone does not report a serial number, so approval covers every device with this USB ID.")
        XCTAssertNil(Presentation.weakIdNote(for: pending("a")))
    }

    func testApprovedDateFormatting() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Presentation.approvalDate(0, timeZone: utc), "1970-01-01")
        XCTAssertEqual(Presentation.approvalDate(1_761_091_200, timeZone: utc), "2025-10-22")
    }

    func testApprovedSerialText() {
        XCTAssertEqual(Presentation.serialText(nil), "no serial")
        XCTAssertEqual(Presentation.serialText("ABC"), "ABC")
        XCTAssertEqual(Presentation.serialText("  "), "no serial")
        XCTAssertEqual(Presentation.serialText("R5\u{202E}8N"), "R58N")
    }

    func testDisplaySerialIsSanitisedLikeNames() {
        XCTAssertEqual(Presentation.displaySerial("R58N"), "R58N")
        XCTAssertEqual(Presentation.displaySerial("A\nB\u{1b}[31m"), "A B[31m")
        XCTAssertEqual(Presentation.displaySerial("  x \t y  "), "x y")
        for invisible in ["\u{200B}", "\u{200F}", "\u{202A}", "\u{202E}", "\u{2066}", "\u{2069}",
                          "\u{FEFF}", "\u{061C}", "\u{2060}", "\u{2061}", "\u{2062}", "\u{2063}",
                          "\u{2064}", "\u{00AD}", "\u{180E}"] {
            XCTAssertEqual(Presentation.displaySerial("R5\(invisible)8N"), "R58N", invisible)
        }
        XCTAssertEqual(Presentation.displaySerial(String(repeating: "a", count: 200)),
                       String(repeating: "a", count: 64))
    }

    func testBlankSerialIsNoSerial() {
        XCTAssertNil(Presentation.displaySerial(nil))
        XCTAssertNil(Presentation.displaySerial(""))
        XCTAssertNil(Presentation.displaySerial(" \t\n "))
        XCTAssertNil(Presentation.displaySerial("\u{200B}\u{2060}"))
    }

    func testWeakIdNoteForBlankSerial() {
        let blank = PendingPhone(requestID: "b", name: "X", vid: 1, pid: 2, serial: "  ")
        XCTAssertNotNil(Presentation.weakIdNote(for: blank))
    }

    func testApprovedIdsOfMissingAndEmptySerialDiffer() {
        let none = ApprovedPhone(name: "X", vid: 1, pid: 2, serial: nil, approvedAt: 0)
        let empty = ApprovedPhone(name: "X", vid: 1, pid: 2, serial: "", approvedAt: 0)
        XCTAssertNotEqual(none.id, empty.id)
    }

    func testVidPidOutOfRangeDoesNotMisprint() {
        XCTAssertEqual(Presentation.vidPid(vid: -1, pid: 0x10000), "????:????")
        XCTAssertEqual(Presentation.vidPid(vid: Int.max, pid: 0xffff), "????:ffff")
    }

    func testCloseWithoutPromptQuitsImmediately() {
        XCTAssertEqual(closeAction(displayedPrompt: nil, isSystemQuit: false), .quit)
        XCTAssertEqual(closeAction(displayedPrompt: nil, isSystemQuit: true), .quit)
    }

    func testCloseWithPromptDeclinesDisplayedPhoneThenQuits() {
        let phone = pending("a")
        XCTAssertEqual(closeAction(displayedPrompt: phone, isSystemQuit: false), .declineThenQuit(phone))
    }

    /// Logout, restart and shutdown are not "Not now": the phone must be asked about again at login.
    func testSystemQuitDoesNotDecline() {
        XCTAssertEqual(closeAction(displayedPrompt: pending("a"), isSystemQuit: true), .quit)
    }

    func testQuitReasonsThatCountAsSystemQuit() {
        for reason in [kAELogOut, kAEReallyLogOut, kAERestart, kAEShowRestartDialog, kAEShutDown,
                       kAEShowShutdownDialog] {
            XCTAssertTrue(isSystemQuitReason(reason), "\(reason)")
        }
        XCTAssertFalse(isSystemQuitReason(nil))
        XCTAssertFalse(isSystemQuitReason(kAEQuitApplication))
    }
}
