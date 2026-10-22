import Foundation

/// A phone waiting for the user to approve or decline it.
public struct PendingPhone: Decodable, Identifiable, Equatable, Sendable {
    public let requestID: String
    public let name: String
    public let vid: Int
    public let pid: Int
    public let serial: String?

    public var id: String { requestID }

    public init(requestID: String, name: String, vid: Int, pid: Int, serial: String?) {
        self.requestID = requestID
        self.name = name
        self.vid = vid
        self.pid = pid
        self.serial = serial
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case name, vid, pid, serial
    }
}

/// A phone the user approved earlier.
public struct ApprovedPhone: Decodable, Identifiable, Equatable, Sendable {
    public let name: String
    public let vid: Int
    public let pid: Int
    public let serial: String?
    public let approvedAt: Int

    public var id: String { "\(vid):\(pid):\(serial ?? "")" }

    public init(name: String, vid: Int, pid: Int, serial: String?, approvedAt: Int) {
        self.name = name
        self.vid = vid
        self.pid = pid
        self.serial = serial
        self.approvedAt = approvedAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, vid, pid, serial
        case approvedAt = "approved_at"
    }
}

/// The active USB tethering link.
public struct PhoneLink: Decodable, Equatable, Sendable {
    public let ip: String
    public let router: String
    public let ifname: String

    public init(ip: String, router: String, ifname: String) {
        self.ip = ip
        self.router = router
        self.ifname = ifname
    }
}

/// The daemon's reply to every successful request.
public struct DaemonStatus: Decodable, Equatable, Sendable {
    public let phone: PhoneLink?
    public let pending: [PendingPhone]
    public let approved: [ApprovedPhone]

    public init(phone: PhoneLink?, pending: [PendingPhone], approved: [ApprovedPhone]) {
        self.phone = phone
        self.pending = pending
        self.approved = approved
    }
}

public enum DaemonError: Error, Equatable, Sendable {
    /// Cannot reach the daemon (no socket, connection refused, timeout).
    case unavailable
    /// The daemon accepted the connection but did not read or answer in time.
    case timedOut
    /// The daemon replied `{"error": ...}`.
    case refused(String)
    /// The reply was empty, oversized, unterminated or not the expected JSON.
    case badReply
}

public protocol DaemonClient: Sendable {
    func status() async throws -> DaemonStatus
    func approve(_ requestID: String) async throws -> DaemonStatus
    func decline(_ requestID: String) async throws -> DaemonStatus
    func remove(_ phone: ApprovedPhone) async throws -> DaemonStatus
}
