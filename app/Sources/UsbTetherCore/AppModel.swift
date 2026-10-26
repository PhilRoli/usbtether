import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public var status: DaemonStatus?
    @Published public var problem: String?
    /// True while an approve, decline or remove is in flight. Further actions
    /// are ignored and background refreshes are skipped until it finishes, so
    /// its reply (and any error in it) is always the one applied.
    @Published public private(set) var busy = false

    private let client: DaemonClient
    /// Incremented by every call; a reply is applied only if no newer call
    /// started meanwhile, so a slow reply cannot overwrite a newer one.
    private var generation = 0
    /// Set when `problem` came from a failed action. A refresh keeps it on
    /// screen until the status changes, instead of wiping it a second later.
    private var actionFailed = false

    public var prompt: PendingPhone? { status?.pending.first }

    public init(client: DaemonClient) {
        self.client = client
    }

    public func refresh() async {
        guard !busy else { return }
        await apply(isAction: false) { try await $0.status() }
    }

    /// Acts on the given phone only; if it is no longer pending the screen
    /// was stale, so nothing is sent and the status is refreshed instead.
    public func approve(_ phone: PendingPhone) async {
        guard !busy else { return }
        guard isPending(phone) else { return await refresh() }
        await act { try await $0.approve(phone.requestID) }
    }

    public func decline(_ phone: PendingPhone) async {
        guard !busy else { return }
        guard isPending(phone) else { return await refresh() }
        await act { try await $0.decline(phone.requestID) }
    }

    public func remove(_ phone: ApprovedPhone) async {
        guard !busy else { return }
        await act { try await $0.remove(phone) }
    }

    private func isPending(_ phone: PendingPhone) -> Bool {
        status?.pending.contains { $0.requestID == phone.requestID } ?? false
    }

    private func act(_ call: (DaemonClient) async throws -> DaemonStatus) async {
        busy = true
        defer { busy = false }
        await apply(isAction: true, call)
    }

    private func apply(isAction: Bool, _ call: (DaemonClient) async throws -> DaemonStatus) async {
        generation += 1
        let token = generation
        do {
            let reply = try await call(client)
            guard token == generation else { return }
            if isAction || !actionFailed || reply != status {
                problem = nil
                actionFailed = false
            }
            status = reply
        } catch let error as DaemonError {
            guard token == generation else { return }
            actionFailed = isAction
            switch error {
            case .unavailable:
                status = nil
                problem = "usbtetherd is not running. Reinstall it with: brew reinstall --cask usbtether"
            case .refused(let message):
                // The daemon answers exactly "not allowed" to a peer that is neither root nor admin.
                problem = "usbtetherd refused the request (\(message))."
                    + (message == "not allowed" ? " Only administrator accounts can approve phones." : "")
            case .timedOut:
                problem = "usbtetherd did not answer in time. Try again."
            case .badReply:
                problem = "Unexpected reply from usbtetherd."
            }
        } catch {
            guard token == generation else { return }
            actionFailed = isAction
            problem = "Unexpected reply from usbtetherd."
        }
    }
}
