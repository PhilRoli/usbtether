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

/// The first call named `gated` blocks until released, then answers `first`; every other
/// call answers `later` at once.
final class GatedClient: DaemonClient, @unchecked Sendable {
    private let gated: String
    private let first: Result<DaemonStatus, DaemonError>
    private let later: DaemonStatus
    private let lock = NSLock()
    private var firstTaken = false
    private var recorded: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    init(gated: String = "status", first: Result<DaemonStatus, DaemonError>, later: DaemonStatus) {
        self.gated = gated
        self.first = first
        self.later = later
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func waitForFirstCall() async {
        await withCheckedContinuation { register($0) }
    }

    func releaseFirst() {
        lock.lock(); let cont = continuation; continuation = nil; lock.unlock()
        cont?.resume()
    }

    private func takeFirst(_ call: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        recorded.append(call)
        let isFirst = call == gated && !firstTaken
        if isFirst { firstTaken = true }
        return isFirst
    }

    private func park(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        continuation = cont
        hasEntered = true
        let waiter = entered; entered = nil
        lock.unlock()
        waiter?.resume()
    }

    private func register(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if hasEntered { lock.unlock(); cont.resume() } else { entered = cont; lock.unlock() }
    }

    private func answer(_ call: String) async throws -> DaemonStatus {
        guard takeFirst(call) else { return later }
        await withCheckedContinuation { park($0) }
        return try first.get()
    }

    func status() async throws -> DaemonStatus { try await answer("status") }
    func approve(_ requestID: String) async throws -> DaemonStatus { try await answer("approve") }
    func decline(_ requestID: String) async throws -> DaemonStatus { try await answer("decline") }
    func remove(_ phone: ApprovedPhone) async throws -> DaemonStatus { try await answer("remove") }
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

    func testModelShowsApprovalWhenPendingAppears() async {
        let client = FakeClient(.success(status()))
        let model = AppModel(client: client)
        await model.refresh()
        XCTAssertNil(model.prompt)
        client.nextStatus = .success(status(pending: [pending("a")]))
        await model.refresh()
        XCTAssertEqual(model.prompt?.name, "Pixel a")
    }

    func testApproveClearsPrompt() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .success(status())
        await model.approve(pending("a"))
        XCTAssertNil(model.prompt)
        XCTAssertEqual(client.calls, ["status", "approve:a"])
    }

    func testDeclineClearsPrompt() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .success(status())
        await model.decline(pending("a"))
        XCTAssertNil(model.prompt)
        XCTAssertEqual(client.calls, ["status", "decline:a"])
    }

    func testApprovingVanishedPhoneSendsNothingAndRefreshes() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .success(status())
        await model.refresh()
        await model.approve(pending("a"))
        await model.decline(pending("a"))
        XCTAssertEqual(client.calls, ["status", "status", "status", "status"])
        XCTAssertNil(model.prompt)
    }

    func testApproveActsOnTheClickedPhoneEvenIfPendingChanged() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        let shown = model.prompt!
        client.nextStatus = .success(status(pending: [pending("b"), pending("a")]))
        await model.refresh()
        XCTAssertEqual(model.prompt?.requestID, "b")
        await model.approve(shown)
        XCTAssertEqual(client.calls.last, "approve:a")
    }

    func testStaleRefreshDoesNotOverwriteNewerApproveReply() async {
        let gated = GatedClient(first: .success(status(pending: [pending("a")])), later: status())
        let model = AppModel(client: gated)
        model.status = status(pending: [pending("a")])
        let slow = Task { await model.refresh() }
        await gated.waitForFirstCall()
        await model.approve(pending("a"))
        XCTAssertNil(model.prompt)
        gated.releaseFirst()
        await slow.value
        XCTAssertNil(model.prompt, "stale refresh must not resurrect the prompt")
    }

    func testTimedOutKeepsStatusAndSetsProblem() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .failure(.timedOut)
        await model.refresh()
        XCTAssertNotNil(model.status)
        XCTAssertEqual(model.problem, "usbtetherd did not answer in time. Try again.")
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
                       "usbtetherd is not running. Reinstall it with: brew reinstall --cask usbtether")
    }

    func testRefusedReplySetsProblem() async {
        let model = AppModel(client: FakeClient(.failure(.refused("not allowed"))))
        await model.refresh()
        XCTAssertEqual(model.problem,
                       "usbtetherd refused the request (not allowed). Only administrator accounts can approve phones.")
    }

    func testOtherRefusalDoesNotBlameTheAccount() async {
        let model = AppModel(client: FakeClient(.failure(.refused("store write failed: disk full"))))
        await model.refresh()
        XCTAssertEqual(model.problem, "usbtetherd refused the request (store write failed: disk full).")
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

    func testActionInFlightIgnoresRepeatsAndRefreshesAndShowsItsError() async {
        let gated = GatedClient(
            gated: "approve", first: .failure(.refused("store write failed: disk full")),
            later: status(pending: [pending("a")]))
        let model = AppModel(client: gated)
        model.status = status(pending: [pending("a")])
        let click = Task { await model.approve(pending("a")) }
        await gated.waitForFirstCall()
        XCTAssertTrue(model.busy)
        await model.approve(pending("a"))
        await model.decline(pending("a"))
        await model.refresh()
        gated.releaseFirst()
        await click.value
        XCTAssertFalse(model.busy)
        XCTAssertEqual(gated.calls, ["approve"], "a double click or a poll must not reach the daemon")
        XCTAssertEqual(model.problem, "usbtetherd refused the request (store write failed: disk full).")
    }

    func testActionErrorSurvivesRefreshUntilStatusChanges() async {
        let client = FakeClient(.success(status(pending: [pending("a")])))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .failure(.refused("store write failed: disk full"))
        await model.approve(pending("a"))
        client.nextStatus = .success(status(pending: [pending("a")]))
        await model.refresh()
        XCTAssertEqual(model.problem, "usbtetherd refused the request (store write failed: disk full).")
        client.nextStatus = .success(status())
        await model.refresh()
        XCTAssertNil(model.problem, "once the phone is gone the error is stale")
    }

    func testRefreshErrorIsClearedByTheNextRefresh() async {
        let client = FakeClient(.success(status()))
        let model = AppModel(client: client)
        await model.refresh()
        client.nextStatus = .failure(.timedOut)
        await model.refresh()
        client.nextStatus = .success(status())
        await model.refresh()
        XCTAssertNil(model.problem)
    }
}
