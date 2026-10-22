import Darwin
import Foundation
import XCTest
@testable import UsbTetherCore

/// One-shot unix socket server on a background thread: accepts a single
/// connection, records the request line and writes `reply` back.
final class FakeServer: @unchecked Sendable {
    private static let counter = NSLock()
    nonisolated(unsafe) private static var next = 0

    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var received = Data()
    private let done = DispatchSemaphore(value: 0)

    init(reply: Data, closeWithoutReading: Bool = false) throws {
        FakeServer.counter.lock()
        FakeServer.next += 1
        path = "/tmp/ut-\(getpid())-\(FakeServer.next).sock"
        FakeServer.counter.unlock()
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else { throw DaemonError.unavailable }
        let fd = listenFD
        Thread.detachNewThread { [self] in
            let conn = accept(fd, nil, nil)
            defer { close(conn); done.signal() }
            guard conn >= 0 else { return }
            var one: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var buf = [UInt8](repeating: 0, count: 4096)
            if !closeWithoutReading {
                var got = Data()
                while !got.contains(0x0a) {
                    let n = read(conn, &buf, buf.count)
                    if n <= 0 { break }
                    got.append(contentsOf: buf[0..<n])
                }
                lock.lock(); received = got; lock.unlock()
            }
            reply.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(conn, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
    }

    var request: String {
        lock.lock(); defer { lock.unlock() }
        return String(bytes: received, encoding: .utf8) ?? ""
    }

    func finish() {
        _ = done.wait(timeout: .now() + 5)
        close(listenFD)
        unlink(path)
    }
}

final class SocketClientTests: XCTestCase {
    func testDecodesDaemonStatusJSON() throws {
        let json = """
        {"phone":{"ip":"192.168.42.129","router":"192.168.42.1","ifname":"en9"},
         "pending":[{"request_id":"r1","name":"Pixel 8","vid":6353,"pid":20193,"serial":null}],
         "approved":[{"name":"Galaxy","vid":1256,"pid":26720,"serial":"ABC","approved_at":1700000000}]}
        """
        let s = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.phone?.ifname, "en9")
        XCTAssertEqual(s.pending.first?.requestID, "r1")
        XCTAssertEqual(s.pending.first?.id, "r1")
        XCTAssertNil(s.pending.first?.serial)
        XCTAssertEqual(s.approved.first?.approvedAt, 1_700_000_000)
        XCTAssertEqual(s.approved.first?.serial, "ABC")
    }

    func testDecodesNullPhoneAndEmptyLists() throws {
        let s = try JSONDecoder().decode(
            DaemonStatus.self, from: Data(#"{"phone":null,"pending":[],"approved":[]}"#.utf8))
        XCTAssertNil(s.phone)
        XCTAssertTrue(s.pending.isEmpty)
    }

    func testSocketClientTalksToAFakeUnixServer() async throws {
        let reply = #"{"phone":null,"pending":[{"request_id":"r1","name":"Pixel","vid":1,"pid":2,"serial":null}],"#
            + #""approved":[]}"#
        let server = try FakeServer(reply: Data((reply + "\n").utf8))
        defer { server.finish() }
        let s = try await SocketDaemonClient(path: server.path).status()
        XCTAssertEqual(s.pending.first?.requestID, "r1")
        XCTAssertEqual(server.request, #"{"cmd":"status"}"# + "\n")
    }

    func testRequestEncodings() async throws {
        let ok = Data((#"{"phone":null,"pending":[],"approved":[]}"# + "\n").utf8)
        var server = try FakeServer(reply: ok)
        _ = try await SocketDaemonClient(path: server.path).approve("r1")
        server.finish()
        XCTAssertEqual(server.request, #"{"cmd":"approve","request_id":"r1"}"# + "\n")

        server = try FakeServer(reply: ok)
        _ = try await SocketDaemonClient(path: server.path).decline("r2")
        server.finish()
        XCTAssertEqual(server.request, #"{"cmd":"decline","request_id":"r2"}"# + "\n")

        server = try FakeServer(reply: ok)
        let phone = ApprovedPhone(name: "P", vid: 1, pid: 2, serial: nil, approvedAt: 0)
        _ = try await SocketDaemonClient(path: server.path).remove(phone)
        server.finish()
        XCTAssertEqual(server.request, #"{"cmd":"remove","pid":2,"serial":null,"vid":1}"# + "\n")
    }

    func testErrorReplyMapsToRefused() async throws {
        let server = try FakeServer(reply: Data(("{\"error\":\"not allowed\"}\n").utf8))
        defer { server.finish() }
        do {
            _ = try await SocketDaemonClient(path: server.path).status()
            XCTFail("expected throw")
        } catch let error as DaemonError {
            XCTAssertEqual(error, .refused("not allowed"))
        }
    }

    func testMissingSocketIsUnavailable() async {
        do {
            _ = try await SocketDaemonClient(path: "/tmp/ut-does-not-exist.sock").status()
            XCTFail("expected throw")
        } catch let error as DaemonError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testOverlongPathIsUnavailable() async {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        do {
            _ = try await SocketDaemonClient(path: path).status()
            XCTFail("expected throw")
        } catch let error as DaemonError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testReplyWithoutNewlineIsBadReply() async throws {
        let server = try FakeServer(reply: Data(#"{"phone":null,"pending":[],"approved":[]}"#.utf8))
        defer { server.finish() }
        await assertBadReply(server)
    }

    func testEmptyReplyIsBadReply() async throws {
        let server = try FakeServer(reply: Data("\n".utf8))
        defer { server.finish() }
        await assertBadReply(server)
    }

    func testOversizedReplyIsBadReply() async throws {
        let server = try FakeServer(reply: Data(repeating: 0x61, count: 1_200_000))
        defer { server.finish() }
        await assertBadReply(server)
    }

    func testGarbageReplyIsBadReply() async throws {
        let server = try FakeServer(reply: Data("not json\n".utf8))
        defer { server.finish() }
        await assertBadReply(server)
    }

    private func assertBadReply(_ server: FakeServer, line: UInt = #line) async {
        do {
            _ = try await SocketDaemonClient(path: server.path).status()
            XCTFail("expected throw", line: line)
        } catch let error as DaemonError {
            XCTAssertEqual(error, .badReply, line: line)
        } catch {
            XCTFail("wrong error \(error)", line: line)
        }
    }
}
