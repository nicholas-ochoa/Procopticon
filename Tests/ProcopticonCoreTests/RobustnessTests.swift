import XCTest
@testable import ProcopticonCore
import ProcopticonExpressions

/// Input that used to crash, hang or mislead: damaged files, absurd numbers, requests for pid 0.
final class RobustnessTests: XCTestCase {
    private func temporaryFile(_ bytes: [UInt8]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("procopticon-test-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    private func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    private func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    private func be64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

    /// A 64-bit Mach-O header announcing `commands` load commands, followed by `body`.
    private func machO(commands: UInt32, _ body: [UInt8]) -> [UInt8] {
        le32(0xfeedfacf) + le32(0x0100000c) + le32(0) + le32(2) + le32(commands) + le32(UInt32(body.count)) + le32(0) + le32(0) + body
    }

    func testTruncatedUUIDCommand() throws {
        // LC_UUID's header with the UUID itself cut off.
        let file = try MachOFile.load(path: temporaryFile(machO(commands: 1, le32(0x1b) + le32(24))))
        XCTAssertNil(file.uuid)
        XCTAssertEqual(file.loadCommands.map(\.name), ["LC_UUID"])
    }

    func testFatSliceBeyondTheFile() throws {
        for offset in [UInt64.max, UInt64(Int.max), UInt64(Int.max) - 10, 1 << 40] {
            let fat = be32(0xcafebabf) + be32(1) + be32(0x0100000c) + be32(0) + be64(offset) + be64(.max) + be32(0) + be32(0)
            XCTAssertThrowsError(try MachOFile.load(path: temporaryFile(fat)), "offset \(offset)")
        }
    }

    func testAbsurdSectionSizesAndAddresses() throws {
        func name(_ s: String) -> [UInt8] { Array(s.utf8) + [UInt8](repeating: 0, count: 16 - s.utf8.count) }
        func section(_ sect: String, flags: UInt32) -> [UInt8] {
            name(sect) + name("__TEXT") + le64(.max) + le64(.max) + le32(8) + le32(0) + le32(0) + le32(0) + le32(flags)
                + le32(0) + le32(0) + le32(0)
        }
        let sections = section("__info_plist", flags: 0) + section("__cstring", flags: 2)
        let segment = le32(0x19) + le32(UInt32(72 + sections.count)) + name("__TEXT") + le64(.max) + le64(.max) + le64(0) + le64(.max)
            + le32(7) + le32(5) + le32(2) + le32(0) + sections
        let main = le32(0x8000_0028) + le32(24) + le64(1) + le64(0)
        let file = try MachOFile.load(path: temporaryFile(machO(commands: 2, segment + main)))
        XCTAssertNil(file.embeddedInfoPlist)
        XCTAssertEqual(file.entryPoint, 0, "wraps rather than traps")
        XCTAssertNoThrow(try file.strings())
    }

    /// Lines a name with a line break in it could put into a tool's output.
    func testReversedRangesInToolOutput() {
        XCTAssertTrue(ProcessDetails.parseVmmapModules("__TEXT 2000-1000 [ 4K] r-x/r-x SM=COW /usr/lib/x.dylib").isEmpty)
        let dump = """
         #1:
                         UUID: A
                         Name: odd
                         Type: legacy daemon (0x10010)
                        Flags: ] [ (0x0)
                  Disposition: ] enabled [ (0xb)
                   Identifier: 16.com.example.odd
                          URL: /Library/LaunchDaemons/com.example.odd.plist
        """
        _ = StartupItems.parseBTM(dump)
    }

    /// Thousands of sections that each claim the same megabyte of text.
    func testOverlappingStringSectionsAreBounded() throws {
        let text = [UInt8](repeating: 0x41, count: 1 << 20)
        let count = 200
        // LC_SEGMENT_64 with `count` S_REGULAR sections, all over the text that follows.
        let commandSize = 72 + 80 * count
        let textOffset = 32 + commandSize
        func name(_ s: String) -> [UInt8] { Array(s.utf8) + [UInt8](repeating: 0, count: 16 - s.utf8.count) }
        var command = le32(0x19) + le32(UInt32(commandSize)) + name("__DATA") + le64(0) + le64(UInt64(text.count))
            + le64(UInt64(textOffset)) + le64(UInt64(text.count)) + le32(3) + le32(3) + le32(UInt32(count)) + le32(0)
        for _ in 0..<count {
            command += name("__const") + name("__DATA") + le64(0) + le64(UInt64(text.count)) + le32(UInt32(textOffset))
                + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0)
        }
        let file = try MachOFile.load(path: temporaryFile(machO(commands: 1, command) + text))
        let result = try file.strings()
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.strings.count, 5)
    }

    func testCPUTimeRoundsIntoTheNextMinute() {
        XCTAssertEqual(Fmt.duration(seconds: 59.9996), "1:00.000")
        XCTAssertEqual(Fmt.duration(seconds: 59.9994), "0:59.999")
        XCTAssertEqual(Fmt.duration(seconds: 3599.9999), "1:00:00.000")
        XCTAssertEqual(Fmt.duration(seconds: 3725.5), "1:02:05.500")
        XCTAssertEqual(Fmt.duration(seconds: 0), "0:00.000")
        XCTAssertEqual(Fmt.duration(seconds: -.infinity), "0:00.000")
        XCTAssertFalse(Fmt.duration(seconds: .greatestFiniteMagnitude).isEmpty)
    }

    func testAlertThresholdsOfAnySize() {
        XCTAssertEqual(AlertRule.number(40), "40")
        XCTAssertEqual(AlertRule.number(2.5), "2.5")
        XCTAssertEqual(AlertRule.number(1e19), "10000000000000000000")
        XCTAssertEqual(AlertRule.number(.infinity), "inf")
        XCTAssertFalse(AlertRule.number(.nan).isEmpty)
    }

    func testPriorityRequestsForPidZeroAreRefused() {
        // To setpriority, pid 0 is the calling process: this test, or in the app the root helper.
        let executor = PrivilegedExecutor(restrictTools: true)
        let before = getpriority(PRIO_PROCESS, 0)
        XCTAssertEqual(executor.handle(.setPriority(pid: 0, nice: 20, startMicros: nil)).error?.code, EINVAL)
        XCTAssertEqual(executor.handle(.setBackground(pid: 0, enabled: true, startMicros: nil)).error?.code, EINVAL)
        XCTAssertEqual(executor.handle(.setPriority(pid: -1, nice: 20, startMicros: nil)).error?.code, EINVAL)
        XCTAssertEqual(getpriority(PRIO_PROCESS, 0), before)
    }

    func testAppAndHelperStreamsNeverShareAnId() {
        let app = ToolStreamSessions(inApp: true)
        let helper = ToolStreamSessions(inApp: false)
        defer { app.stopAll(); helper.stopAll() }
        var ids: [Int] = []
        for sessions in [app, app, helper, helper] {
            guard case .streamStarted(let id) = sessions.start("/bin/sleep", ["30"]) else { return XCTFail("didn't start") }
            ids.append(id)
        }
        XCTAssertEqual(ids, [-1, -2, 1, 2])
        // Reads and stops of the app's own streams stay in the app once the helper is running.
        XCTAssertTrue(Elevation.isLocalStream(.readStream(id: -1)))
        XCTAssertTrue(Elevation.isLocalStream(.stopStream(id: -2)))
        XCTAssertFalse(Elevation.isLocalStream(.readStream(id: 1)))
        XCTAssertFalse(Elevation.isLocalStream(.startStream(tool: "/bin/sleep", arguments: [])))
    }

    func testCompileErrorsCannotHangOnAReplacedToString() {
        let engine = ProcessExpressionEngine()
        let r = ProcessRecord(pid: 1, ppid: 0, pgid: 1, uid: 0, ruid: 0, rgid: 0, svuid: 0, status: 2,
                              flags: 0, nice: 0, tty: -1, startMicros: 1, comm: "launchd")
        let item = ProcessItem(ProcessState(record: r, time: 0, initial: true))
        // Globals outlive an expression, so one can booby-trap how later errors are described.
        _ = engine.compile("(Error.prototype.toString = () => { for (;;); }, SyntaxError.prototype.toString = Error.prototype.toString, true)")
            .evaluate(item)
        let started = Date()
        XCTAssertNotNil(engine.compile("cpu >").error)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testOneUnreadableEntryDoesNotLoseTheList() throws {
        let rules = [AlertRule(trigger: .cpu, threshold: 40, duration: 10), AlertRule(trigger: .memory, threshold: 1, duration: 0)]
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rules)) as? [[String: Any]])
        entries.insert(["trigger": "somethingNewer", "threshold": 1], at: 1)
        let data = try JSONSerialization.data(withJSONObject: entries)
        XCTAssertNil(try? JSONDecoder().decode([AlertRule].self, from: data), "the list as a whole is unreadable")
        XCTAssertEqual(LenientList.decode(AlertRule.self, from: data)?.map(\.trigger), [.cpu, .memory])
        XCTAssertNil(LenientList.decode(AlertRule.self, from: Data("{}".utf8)))
    }
}
