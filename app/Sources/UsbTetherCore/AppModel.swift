import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public var status: DaemonStatus?
    @Published public var problem: String?

    private let client: DaemonClient
    /// Incremented by every call; a reply is applied only if no newer call
    /// started meanwhile, so a slow reply cannot overwrite a newer one.
    private var generation = 0

    public var prompt: PendingPhone? { status?.pending.first }

    public init(client: DaemonClient) {
        self.client = client
    }

    public func refresh() async {
        await apply { try await $0.status() }
    }

    /// Acts on the given phone only; if it is no longer pending the screen
    /// was stale, so nothing is sent and the status is refreshed instead.
    public func approve(_ phone: PendingPhone) async {
        guard isPending(phone) else { return await refresh() }
        await apply { try await $0.approve(phone.requestID) }
    }

    public func decline(_ phone: PendingPhone) async {
        guard isPending(phone) else { return await refresh() }
        await apply { try await $0.decline(phone.requestID) }
    }

    public func remove(_ phone: ApprovedPhone) async {
        await apply { try await $0.remove(phone) }
    }

    private func isPending(_ phone: PendingPhone) -> Bool {
        status?.pending.contains { $0.requestID == phone.requestID } ?? false
    }

    private func apply(_ call: (DaemonClient) async throws -> DaemonStatus) async {
        generation += 1
        let token = generation
        do {
            let reply = try await call(client)
            guard token == generation else { return }
            status = reply
            problem = nil
        } catch let error as DaemonError {
            guard token == generation else { return }
            switch error {
            case .unavailable:
                status = nil
                problem = "usbtetherd is not running. Install it with: brew install --cask usbtether"
            case .refused(let message):
                problem = "usbtetherd refused the request (\(message)). "
                    + "Only administrator accounts can approve phones."
            case .timedOut:
                problem = "usbtetherd did not answer in time. Try again."
            case .badReply:
                problem = "Unexpected reply from usbtetherd."
            }
        } catch {
            guard token == generation else { return }
            problem = "Unexpected reply from usbtetherd."
        }
    }
}
