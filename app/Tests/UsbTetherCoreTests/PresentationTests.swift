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
    }

    func testVidPidOutOfRangeDoesNotMisprint() {
        XCTAssertEqual(Presentation.vidPid(vid: -1, pid: 0x10000), "????:????")
        XCTAssertEqual(Presentation.vidPid(vid: Int.max, pid: 0xffff), "????:ffff")
    }

    func testCloseWithoutPromptQuitsImmediately() {
        XCTAssertEqual(closeAction(displayedPrompt: nil), .quit)
    }

    func testCloseWithPromptDeclinesDisplayedPhoneThenQuits() {
        let phone = pending("a")
        XCTAssertEqual(closeAction(displayedPrompt: phone), .declineThenQuit(phone))
    }
}
