import XCTest
@testable import UsbTetherCore

final class FakeClient: DaemonClient, @unchecked Sendable {
    var nextStatus: Result<DaemonStatus, DaemonError>
    private(set) var calls: [String] = []

    init(_ status: Result<DaemonStatus, DaemonError>) {
        nextStatus = status
    }

    private func answer(_ call: String) throws -> DaemonStatus {
        calls.append(call)
        return try nextStatus.get()
    }

    func status() async throws -> DaemonStatus { try answer("status") }
    func approve(_ requestID: String) async throws -> DaemonStatus { try answer("approve:\(requestID)") }
    func decline(_ requestID: String) async throws -> DaemonStatus { try answer("decline:\(requestID)") }
    func remove(_ phone: ApprovedPhone) async throws -> DaemonStatus { try answer("remove:\(phone.name)") }
}

func pending(_ id: String) -> PendingPhone {
    PendingPhone(requestID: id, name: "Pixel \(id)", vid: 0x18d1, pid: 0x4ee1, serial: "S\(id)")
}

func status(pending: [PendingPhone] = [], approved: [ApprovedPhone] = []) -> DaemonStatus {
    DaemonStatus(phone: nil, pending: pending, approved: approved)
}

@MainActor
final class AppModelTests: XCTestCase {
    func testPromptIsFirstPending() async {
        let model = AppModel(client: FakeClient(.success(status(pending: [pending("a"), pending("b")]))))
        XCTAssertNil(model.prompt)
        await model.refresh()
        XCTAssertEqual(model.prompt?.requestID, "a")
        XCTAssertNil(model.problem)
    }

    func testApproveClearsPrompt() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .success(status())
        await model.approve()
        XCTAssertNil(model.prompt)
        XCTAssertEqual(client.calls, ["status", "approve:a"])
    }

    func testDeclineClearsPrompt() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .success(status())
        await model.decline()
        XCTAssertNil(model.prompt)
        XCTAssertEqual(client.calls, ["status", "decline:a"])
    }

    func testApproveWithoutPromptIsNoOp() async {
        let client = FakeClient(.success(status()))
        let model = AppModel(client: client)
        await model.approve()
        await model.decline()
        XCTAssertEqual(client.calls, [])
    }

    func testRemoveUpdatesStatus() async {
        let phone = ApprovedPhone(name: "P", vid: 1, pid: 2, serial: nil, approvedAt: 3)
        let client = FakeClient(.success(status(approved: [phone])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .success(status())
        await model.remove(phone)
        XCTAssertEqual(model.status?.approved.count, 0)
        XCTAssertEqual(client.calls.last, "remove:P")
    }

    func testUnavailableDaemonSetsProblemText() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .failure(.unavailable)
        await model.refresh()
        XCTAssertNil(model.status)
        XCTAssertEqual(model.problem,
                       "usbtetherd is not running. Install it with: brew install --cask usbtether")
    }

    func testRefusedReplySetsProblem() async {
        let model = AppModel(client: FakeClient(.failure(.refused("not allowed"))))
        await model.refresh()
        XCTAssertEqual(model.problem,
                       "usbtetherd refused the request (not allowed). Only administrator accounts can approve phones.")
    }

    func testBadReplySetsProblem() async {
        let model = AppModel(client: FakeClient(.failure(.badReply)))
        await model.refresh()
        XCTAssertEqual(model.problem, "Unexpected reply from usbtetherd.")
    }

    func testSuccessClearsProblem() async {
        let client = FakeClient(.failure(.unavailable))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .success(status())
        await model.refresh()
        XCTAssertNil(model.problem)
        XCTAssertNotNil(model.status)
    }
}
