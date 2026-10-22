import Darwin
import Foundation

/// Talks to usbtetherd over its unix socket: one JSON line out, one JSON
/// line back. Blocking socket work runs on a background queue.
public struct SocketDaemonClient: DaemonClient {
    static let maxReply = 1 << 20
    private static let queue = DispatchQueue(label: "usbtether.control", qos: .userInitiated,
                                             attributes: .concurrent)

    public let path: String
    public let timeout: TimeInterval

    public init(path: String = "/var/run/usbtether.sock", timeout: TimeInterval = 2) {
        self.path = path
        self.timeout = timeout
    }

    public func status() async throws -> DaemonStatus {
        try await send(["cmd": "status"])
    }

    public func approve(_ requestID: String) async throws -> DaemonStatus {
        try await send(["cmd": "approve", "request_id": requestID])
    }

    public func decline(_ requestID: String) async throws -> DaemonStatus {
        try await send(["cmd": "decline", "request_id": requestID])
    }

    public func remove(_ phone: ApprovedPhone) async throws -> DaemonStatus {
        let serial: Any = phone.serial ?? NSNull()
        return try await send(["cmd": "remove", "vid": phone.vid, "pid": phone.pid, "serial": serial])
    }

    private func send(_ request: [String: Any]) async throws -> DaemonStatus {
        var line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        line.append(0x0a)
        let payload = line
        let path = self.path
        let timeout = self.timeout
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try Self.exchange(path: path, timeout: timeout, request: payload) })
            }
        }
        return try Self.decode(reply)
    }

    static func decode(_ reply: Data) throws -> DaemonStatus {
        struct ErrorReply: Decodable { let error: String }
        if let failure = try? JSONDecoder().decode(ErrorReply.self, from: reply) {
            throw DaemonError.refused(failure.error)
        }
        do {
            return try JSONDecoder().decode(DaemonStatus.self, from: reply)
        } catch {
            throw DaemonError.badReply
        }
    }

    /// Returns the reply line without its newline.
    static func exchange(path: String, timeout: TimeInterval, request: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.unavailable }
        defer { close(fd) }

        // A stuck daemon must not hang us, and a daemon that closes early
        // must not kill the app with SIGPIPE.
        var tv = timeval(tv_sec: Int(timeout),
                         tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= capacity else { throw DaemonError.unavailable }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw DaemonError.unavailable }

        try writeAll(fd, request)
        return try readLine(fd)
    }

    private static func ioError() -> DaemonError {
        errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .unavailable
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ioError()
                }
                if written == 0 { throw DaemonError.unavailable }
                offset += written
            }
        }
    }

    private static func readLine(_ fd: Int32) throws -> Data {
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError()
            }
            // EOF before a newline: the reply is incomplete.
            if count == 0 { throw DaemonError.badReply }
            if let newline = buffer[0..<count].firstIndex(of: 0x0a) {
                reply.append(contentsOf: buffer[0..<newline])
                guard !reply.isEmpty, reply.count <= maxReply else { throw DaemonError.badReply }
                return reply
            }
            reply.append(contentsOf: buffer[0..<count])
            if reply.count > maxReply { throw DaemonError.badReply }
        }
    }
}
