import XCTest
@testable import ProcopticonCore

final class ToolStreamTests: XCTestCase {
    private func readAll(_ executor: PrivilegedExecutor, _ id: Int, timeout: TimeInterval = 5) -> (String, StreamChunk?) {
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard case .streamOutput(let chunk) = executor.handle(.readStream(id: id)) else { return (text, nil) }
            text += chunk.text
            if chunk.finished { return (text, chunk) }
            usleep(20_000)
        }
        return (text, nil)
    }

    func testOutputArrivesInWholeLinesUntilExit() {
        let executor = PrivilegedExecutor(restrictTools: false)
        guard case .streamStarted(let id) = executor.handle(.startStream(tool: "/bin/sh",
                                                                        arguments: ["-c", "echo one; echo two >&2; sleep 0.2; printf 'three\\nfour'; exit 3"])) else {
            return XCTFail("didn't start")
        }
        let (text, last) = readAll(executor, id)
        XCTAssertEqual(text, "one\nthree\nfour")
        XCTAssertEqual(last?.status, 3)
        XCTAssertEqual(last?.errorOutput, "two\n")
        // The finished session is gone.
        XCTAssertNotNil(executor.handle(.readStream(id: id)).error)
    }

    func testStopEndsTheTool() {
        let executor = PrivilegedExecutor(restrictTools: false)
        guard case .streamStarted(let id) = executor.handle(.startStream(tool: "/bin/sleep", arguments: ["30"])) else {
            return XCTFail("didn't start")
        }
        XCTAssertEqual(executor.handle(.stopStream(id: id)).error?.code, nil)
        XCTAssertNotNil(executor.handle(.readStream(id: id)).error)
    }

    func testHelperOnlyStreamsAllowedTools() {
        let executor = PrivilegedExecutor(restrictTools: true)
        XCTAssertEqual(executor.handle(.startStream(tool: "/bin/sh", arguments: ["-c", "true"])).error?.code, EPERM)
    }

    func testParseLogLine() {
        let line = #"{"messageType":"Error","eventType":"logEvent","subsystem":"com.apple.SkyLight","category":"default","threadID":5211,"senderImagePath":"\/System\/Library\/PrivateFrameworks\/SkyLight.framework\/Versions\/A\/SkyLight","timestamp":"2026-10-09 12:33:35.789327-0500","eventMessage":"_CGXPackagesSetWindowConstraints: Invalid window","processID":416}"#
        let e = UnifiedLog.parse(line, id: 7)
        XCTAssertEqual(e?.id, 7)
        XCTAssertEqual(e?.type, "Error")
        XCTAssertEqual(e?.time, "12:33:35.789327")
        XCTAssertEqual(e?.subsystem, "com.apple.SkyLight")
        XCTAssertEqual(e?.sender, "SkyLight")
        XCTAssertEqual(e?.threadID, 5211)
        XCTAssertEqual(e?.processID, 416)
        XCTAssertEqual(e?.message, "_CGXPackagesSetWindowConstraints: Invalid window")
        let expected = ISO8601DateFormatter().date(from: "2026-10-09T17:33:35Z")!.addingTimeInterval(0.789327)
        XCTAssertEqual(e?.date.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(UnifiedLog.parse("Filtering the log data using \"processID == 1\"", id: 0))
        XCTAssertNil(UnifiedLog.parse(#"{"count":70,"finished":1}"#, id: 0))
    }
}
