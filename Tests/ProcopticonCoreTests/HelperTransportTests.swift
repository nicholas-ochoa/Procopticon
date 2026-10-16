import Darwin
import XCTest
@testable import ProcopticonCore

final class HelperTransportTests: XCTestCase {
    func testSocketLivesInRootsDirectory() {
        XCTAssertEqual(HelperSocket.path(clientPid: 123), "/var/run/procopticon/123.sock")
    }

    func testHelperRunsOnlyTheToolsTheAppUses() {
        let executor = PrivilegedExecutor(restrictTools: true)
        // Each of these can start another program, or write any file, as root.
        for tool in ["/usr/bin/lldb", "/usr/bin/taskpolicy", "/usr/bin/codesign", "/usr/sbin/sysctl", "/bin/sh"] {
            XCTAssertEqual(executor.handle(.runTool(tool: tool, arguments: [])).error?.code, EPERM, tool)
        }
        XCTAssertTrue(AllowedTools.paths.contains("/usr/bin/gcore"))
    }

    /// A helper that accepts the connection but never answers (suspended, say) must not hold the
    /// caller forever.
    func testClientGivesUpOnASilentHelper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)

        let started = Date()
        XCTAssertThrowsError(try HelperClient(socketPath: path).send(.ping)) { error in
            XCTAssertEqual((error as? PrivilegedError)?.code, ETIMEDOUT)
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, PrivilegedRequest.ping.replyTimeout - 0.5)
        XCTAssertLessThan(waited, PrivilegedRequest.ping.replyTimeout + 5)
    }
}
