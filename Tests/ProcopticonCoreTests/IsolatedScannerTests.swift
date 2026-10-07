import XCTest
@testable import ProcopticonCore

final class IsolatedScannerTests: XCTestCase {
    override func tearDown() {
        IsolatedScanner.executablePath = nil
    }

    private var helperPath: String {
        // .build/<config>/ProcopticonCoreTests.xctest/Contents/MacOS/… → .build/<config>/procopticon-helper
        var url = Bundle(for: Self.self).bundleURL
        url.deleteLastPathComponent()
        return url.appendingPathComponent("procopticon-helper").path
    }

    func testScansThroughChildProcess() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helperPath), "helper not built")
        IsolatedScanner.executablePath = helperPath
        // Scan a sibling process we own (a short sleep) through the child scanner.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let results = IsolatedScanner.regions(pids: [sleeper.processIdentifier, getpid()])
        guard case .success(let r) = results[sleeper.processIdentifier] else {
            return XCTFail("expected regions for child: \(String(describing: results[sleeper.processIdentifier]))")
        }
        XCTAssertGreaterThan(r.count, 5)
        guard case .success = results[getpid()] else { return XCTFail("self scan failed") }
    }

    func testRecoversWhenScannerIsKilled() throws {
        // Fake scanner: announces the first pid, then dies like an EXC_GUARD would kill it.
        let script = NSTemporaryDirectory() + "fake-scanner-\(UUID().uuidString).sh"
        try """
        #!/bin/sh
        read first
        echo "#start $first"
        kill -9 $$
        """.write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        defer { try? FileManager.default.removeItem(atPath: script) }
        IsolatedScanner.executablePath = script
        let results = IsolatedScanner.regions(pids: [11111, 22222])
        for pid: Int32 in [11111, 22222] {
            guard case .failure(let e) = results[pid] else { return XCTFail("expected failure for \(pid)") }
            XCTAssertEqual(e.code, .EFAULT)
        }
    }
}
