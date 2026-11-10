import XCTest
@testable import ProcopticonCore

final class ParserTests: XCTestCase {
    func testOwnArgumentsAndEnvironment() throws {
        guard case .success(let args) = ProcessArguments.read(pid: getpid()) else {
            return XCTFail("could not read own arguments")
        }
        XCTAssertFalse(args.arguments.isEmpty)
        XCTAssertFalse(args.executablePath.isEmpty)
        print("environment entries:", args.environment.count)
    }

    func testProcArgsParsing() {
        // argc=2, exec path, padding, argv[0], argv[1], env...
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes += $0 }
        bytes += Array("/bin/tool".utf8) + [0, 0, 0]
        bytes += Array("tool".utf8) + [0] + Array("-v".utf8) + [0]
        bytes += Array("A=1".utf8) + [0] + Array("B=two".utf8) + [0] + [0]
        bytes += Array("executable_path=/bin/tool".utf8) + [0]
        let parsed = bytes.withUnsafeBytes { ProcessArguments.parse($0) }
        XCTAssertEqual(parsed.executablePath, "/bin/tool")
        XCTAssertEqual(parsed.arguments, ["tool", "-v"])
        XCTAssertEqual(parsed.environment, ["A=1", "B=two"])
    }

    func testRetitledProcArgsParsing() {
        // A retitle (libuv) writes the title over argv[0] and zeroes the rest of the argv area.
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/bin/node".utf8) + [0, 0]
        bytes += Array("api".utf8) + [UInt8](repeating: 0, count: 20)
        bytes += Array("A=1".utf8) + [0] + Array("B=two".utf8) + [0] + [0]
        bytes += Array("executable_path=/bin/node".utf8) + [0]
        let parsed = bytes.withUnsafeBytes { ProcessArguments.parse($0) }
        XCTAssertEqual(parsed.arguments, ["api", "", ""])
        XCTAssertEqual(parsed.environment, ["A=1", "B=two"])

        // Only argv[0], shortened by the title.
        bytes = []
        withUnsafeBytes(of: Int32(1)) { bytes += $0 }
        bytes += Array("/bin/node".utf8) + [0, 0]
        bytes += Array("api".utf8) + [UInt8](repeating: 0, count: 8)
        bytes += Array("A=1".utf8) + [0] + [0]
        let single = bytes.withUnsafeBytes { ProcessArguments.parse($0) }
        XCTAssertEqual(single.arguments, ["api"])
        XCTAssertEqual(single.environment, ["A=1"])
    }

    func testEmptyEnvironmentParsing() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(1)) { bytes += $0 }
        bytes += Array("/bin/tool".utf8) + [0, 0]
        bytes += Array("tool".utf8) + [0] + [0]
        bytes += Array("executable_path=/bin/tool".utf8) + [0]
        let parsed = bytes.withUnsafeBytes { ProcessArguments.parse($0) }
        XCTAssertEqual(parsed.arguments, ["tool"])
        XCTAssertEqual(parsed.environment, [])
    }

    func testLaunchctlPrintParsing() {
        let text = """
        system = {
        \ttype = system
        \tservices = {
        \t\t       0      - \tcom.apple.example.stopped
        \t\t    1234      0 \tcom.apple.example.running
        \t}
        \tdisabled services = {
        \t\t"com.example.off" => disabled
        \t\t"com.example.on" => enabled
        \t}
        }
        """
        let parsed = ServiceProvider.parsePrint(text)
        XCTAssertEqual(parsed.services.count, 2)
        XCTAssertEqual(parsed.services[1].label, "com.apple.example.running")
        XCTAssertEqual(parsed.services[1].pid, 1234)
        XCTAssertEqual(parsed.disabled["com.example.off"], true)
        XCTAssertEqual(parsed.disabled["com.example.on"], false)
    }

    func testVmmapModuleParsing() {
        let text = """
        __TEXT                      104880000-105354000    [ 10.8M  7952K     0K     0K] r-x/r-x SM=COW          /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
        __DATA                      105354000-105400000    [ 10.8M  7952K     0K     0K] rw-/rw- SM=COW          /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
        __TEXT                      187994000-1879e4000    [  320K   304K     0K     0K] r-x/r-x SM=COW          /usr/lib/libobjc.A.dylib
        """
        let mods = ProcessDetails.parseVmmapModules(text)
        XCTAssertEqual(mods.count, 2)
        XCTAssertEqual(mods[0].name, "Finder")
        XCTAssertEqual(mods[0].baseAddress, 0x104880000)
        XCTAssertEqual(mods[1].path, "/usr/lib/libobjc.A.dylib")
    }

    func testMachOParsing() throws {
        let f = try MachOFile.load(path: "/bin/ls")
        XCTAssertEqual(f.fileType, 0x2)
        XCTAssertTrue(f.dylibs.contains { $0.path.contains("libSystem") })
        XCTAssertNotNil(f.uuid)
        XCTAssertGreaterThanOrEqual(f.slices.count, 1)
    }

    func testSelfDetails() {
        guard case .success(let fds) = ProcessDetails.fileDescriptors(pid: getpid()) else { return XCTFail() }
        XCTAssertTrue(fds.contains { $0.fd == 0 })
        guard case .success(let threads) = ProcessDetails.threads(pid: getpid()) else { return XCTFail() }
        XCTAssertGreaterThan(threads.count, 0)
        guard case .success(let regions) = ProcessDetails.regions(pid: getpid()) else { return XCTFail() }
        XCTAssertGreaterThan(regions.count, 10)
        XCTAssertFalse(ProcessDetails.modulesFromRegions(regions).isEmpty)
    }

    func testExecutorSignalPermission() {
        let r = PrivilegedExecutor(restrictTools: true).handle(.signal(pid: 1, signal: 0, startMicros: nil))
        if geteuid() != 0 {
            XCTAssertEqual(r.error?.isPermissionDenied, true)
        }
        // A PID whose process has been replaced is left alone, whatever the privileges.
        let me = ProcessKey.current(pid: getpid())
        XCTAssertNotNil(me)
        XCTAssertEqual(me?.isRunning, true)
        let stale = PrivilegedExecutor(restrictTools: true)
            .handle(.signal(pid: getpid(), signal: 0, startMicros: (me?.startMicros ?? 0) - 1))
        XCTAssertEqual(stale.error?.code, ESRCH)
        let same = PrivilegedExecutor(restrictTools: true)
            .handle(.signal(pid: getpid(), signal: 0, startMicros: me?.startMicros))
        XCTAssertNil(same.error)
        let denied = PrivilegedExecutor(restrictTools: true).handle(.runTool(tool: "/bin/sh", arguments: []))
        XCTAssertNotNil(denied.error)
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.bytes(UInt64(1536)), "1.50 KB")
        XCTAssertEqual(["a b", "c"].shellJoined, "'a b' c")
        var h = History(capacity: 3)
        [1, 2, 3, 4].forEach { h.append(Double($0)) }
        XCTAssertEqual(h.ordered, [2, 3, 4])
    }
}

final class BundlePathTests: XCTestCase {
    func testEnclosingBundlePath() {
        XCTAssertEqual(BundleInfoCache.enclosingBundlePath("/Applications/Sublime Text.app/Contents/MacOS/sublime_text"),
                       "/Applications/Sublime Text.app")
        XCTAssertEqual(BundleInfoCache.enclosingBundlePath("/System/Library/Frameworks/A.framework/Versions/A/XPCServices/S.xpc/Contents/MacOS/S"),
                       "/System/Library/Frameworks/A.framework/Versions/A/XPCServices/S.xpc")
        XCTAssertNil(BundleInfoCache.enclosingBundlePath("/usr/bin/top"))
        XCTAssertNil(BundleInfoCache.enclosingBundlePath("top"))
    }
}
