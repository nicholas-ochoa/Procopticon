import XCTest
@testable import ProcopticonCore

final class DiagnosticReportTests: XCTestCase {
    private let crash = """
    {"app_name":"Hierax","timestamp":"2026-10-09 09:09:38.00 -0500","app_version":"0.1","build_version":"1","bundleID":"app.hierax.Hierax","bug_type":"309","name":"Hierax"}
    {"procName":"Hierax","pid":30470,"procPath":"/Applications/Hierax.app/Contents/MacOS/Hierax","parentProc":"launchd","parentPid":1,
     "exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP","codes":"0x1, 0x2"},
     "termination":{"namespace":"SIGNAL","code":5,"indicator":"Trace/BPT trap: 5","byProc":"exc handler","byPid":30470},
     "faultingThread":1,
     "threads":[{"id":1,"frames":[{"imageOffset":16,"imageIndex":0}]},
                {"id":2,"queue":"com.apple.main-thread","triggered":true,"frames":[{"imageOffset":4038104,"symbol":"+[NSApplication _crashOnException:]","symbolLocation":268,"imageIndex":0}]}],
     "usedImages":[{"name":"AppKit","base":4096,"size":8192,"uuid":"U","path":"/System/Library/Frameworks/AppKit.framework/AppKit"}]}
    """

    func testCrashReport() throws {
        let r = try XCTUnwrap(DiagnosticReports.parseIPS(crash, path: "/x/Hierax-2026-10-09-090938.ips", retired: false, fallbackDate: .distantPast))
        XCTAssertEqual(r.kind, .crash)
        XCTAssertEqual(r.processName, "Hierax")
        XCTAssertEqual(r.summary, "EXC_BREAKPOINT (SIGTRAP)")
        XCTAssertEqual(r.version, "0.1 (1)")
        XCTAssertEqual(r.pid, 30470)
        XCTAssertEqual(r.bundleIdentifier, "app.hierax.Hierax")
        XCTAssertEqual(r.date, ISO8601DateFormatter().date(from: "2026-10-09T14:09:38Z"))
        XCTAssertTrue(r.concerns(path: "/Applications/Hierax.app/Contents/MacOS/Hierax", name: "x", bundleIdentifier: nil))
        XCTAssertTrue(r.concerns(path: nil, name: "Hierax", bundleIdentifier: nil))
        XCTAssertFalse(r.concerns(path: "/bin/ls", name: "ls", bundleIdentifier: "com.example"))
    }

    func testReadableCrashPutsTheCrashedThreadFirst() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(crash.split(separator: "\n", maxSplits: 1)[1].utf8)) as? [String: Any])
        let text = DiagnosticReports.formatCrash(body)
        XCTAssertTrue(text.contains("Exception type:   EXC_BREAKPOINT (SIGTRAP)"))
        let crashed = try XCTUnwrap(text.range(of: "Thread 1 Crashed:"))
        let other = try XCTUnwrap(text.range(of: "Thread 0:"))
        XCTAssertLessThan(crashed.lowerBound, other.lowerBound)
        XCTAssertTrue(text.contains("+[NSApplication _crashOnException:] + 268"))
        XCTAssertTrue(text.contains("0x0000000000001010 AppKit + 16"), text)
    }

    func testJetsamReportNamesTheKilledProcesses() throws {
        let jetsam = """
        {"bug_type":"298","timestamp":"2026-10-02 22:09:09.00 -0500","incident_id":"X"}
        {"processes":[{"name":"IMTranscoderAgent","pid":5,"reason":"per-process-limit"},{"name":"Finder","pid":6}]}
        """
        let r = try XCTUnwrap(DiagnosticReports.parseIPS(jetsam, path: "/x/JetsamEvent-2026-10-02-220909.ips", retired: true, fallbackDate: .distantPast))
        XCTAssertEqual(r.kind, .memory)
        XCTAssertEqual(r.killedProcesses, ["IMTranscoderAgent"])
        XCTAssertTrue(r.concerns(path: nil, name: "IMTranscoderAgent", bundleIdentifier: nil))
        XCTAssertFalse(r.concerns(path: nil, name: "Finder", bundleIdentifier: nil))
        XCTAssertTrue(r.isRetired)
    }

    func testResourceReport() throws {
        let diag = """
        Date/Time:        2026-10-05 19:09:16.353 -0500
        End time:         2026-10-06 12:30:21.622 -0500
        Command:          Claude
        Path:             /Applications/Claude.app/Contents/MacOS/Claude
        Identifier:       com.anthropic.claudefordesktop
        Version:          2.19675.0 (2.19675.0)
        PID:              61318

        Event:            disk writes
        Action taken:     none
        """
        let r = try XCTUnwrap(DiagnosticReports.parseText(diag, path: "/x/Claude_2026-10-06-123022_mbp.diag", retired: false, fallbackDate: .distantPast))
        XCTAssertEqual(r.kind, .diskWrites)
        XCTAssertEqual(r.processName, "Claude")
        XCTAssertEqual(r.pid, 61318)
        XCTAssertEqual(r.summary, "disk writes")
        XCTAssertEqual(r.bundleIdentifier, "com.anthropic.claudefordesktop")
    }
}
