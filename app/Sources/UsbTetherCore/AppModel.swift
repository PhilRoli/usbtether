import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public var status: DaemonStatus?
    @Published public var problem: String?

    private let client: DaemonClient

    public var prompt: PendingPhone? { status?.pending.first }

    public init(client: DaemonClient) {
        self.client = client
    }

    public func refresh() async {
        await apply { try await $0.status() }
    }

    public func approve() async {
        guard let id = prompt?.requestID else { return }
        await apply { try await $0.approve(id) }
    }

    public func decline() async {
        guard let id = prompt?.requestID else { return }
        await apply { try await $0.decline(id) }
    }

    public func remove(_ phone: ApprovedPhone) async {
        await apply { try await $0.remove(phone) }
    }

    private func apply(_ call: (DaemonClient) async throws -> DaemonStatus) async {
        do {
            status = try await call(client)
            problem = nil
        } catch let error as DaemonError {
            switch error {
            case .unavailable:
                status = nil
                problem = "usbtetherd is not running. Install it with: brew install --cask usbtether"
            case .refused(let message):
                problem = "usbtetherd refused the request (\(message)). "
                    + "Only administrator accounts can approve phones."
            case .badReply:
                problem = "Unexpected reply from usbtetherd."
            }
        } catch {
            problem = "Unexpected reply from usbtetherd."
        }
    }
}
