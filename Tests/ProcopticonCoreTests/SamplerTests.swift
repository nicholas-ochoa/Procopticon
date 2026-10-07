import XCTest
@testable import ProcopticonCore

final class SamplerTests: XCTestCase {
    func testSampleIncludesSelf() {
        let records = ProcessSampler().sample()
        XCTAssertGreaterThan(records.count, 10)
        let me = records.first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertNotNil(me?.stats)
        XCTAssertNotNil(me?.path)
        XCTAssertNotNil(me?.arguments)
    }

    func testCustomTitle() {
        let node = "/Users/me/.local/share/mise/installs/node/24.14.0/bin/node"
        func title(_ args: [String], _ path: String? = node, comm: String = "node") -> String? {
            ProcessRecord.customTitle(arguments: args, path: path, comm: comm)
        }
        // Started by name, path, relative path or a version-manager shim: not a title.
        XCTAssertNil(title(["node", "server.js"]))
        XCTAssertNil(title([node, "server.js"]))
        XCTAssertNil(title(["./bin/node"]))
        XCTAssertNil(title(["/Users/me/.local/share/mise/shims/node", "server.js"]))
        // Login shells.
        XCTAssertNil(title(["-zsh"], "/bin/zsh", comm: "zsh"))
        XCTAssertNil(title(["-/bin/zsh"], "/bin/zsh", comm: "zsh"))
        // An existing file, or a command on PATH, under a different name than the binary
        // (e.g. Homebrew's python3 re-executing Python.app).
        XCTAssertNil(title(["/bin/ls", "-l"], "/opt/Python.app/Contents/MacOS/Python", comm: "Python"))
        XCTAssertNil(title(["ls", "-l"], "/opt/Python.app/Contents/MacOS/Python", comm: "Python"))
        // comm is cut to 16 bytes.
        XCTAssertNil(title(["com.apple.WebKit.Networking"], "/x/Networking", comm: "com.apple.WebKit"))
        // Real titles: only argv[0] is shown.
        XCTAssertEqual(title(["example-api [node] [dev] [main]", "", ""]), "example-api [node] [dev] [main]")
        XCTAssertEqual(title(["my-worker", "--port", "80"]), "my-worker")
        XCTAssertEqual(title(["postgres: checkpointer"], "/opt/pg/bin/postgres", comm: "postgres"), "postgres: checkpointer")
        // Nothing to show.
        XCTAssertNil(title([]))
        XCTAssertNil(title([""]))
        XCTAssertNil(title(["zsh"], nil))
    }

    func testCommandLineOfRetitledProcess() {
        var r = ProcessRecord(pid: 1, ppid: 0, pgid: 1, uid: 0, ruid: 0, rgid: 0, svuid: 0, status: 2, flags: 0,
                              nice: 0, tty: 0, startMicros: 0, comm: "node")
        r.path = "/bin/node"
        r.arguments = ["api [dev]", "", ""]
        r.title = "api [dev]"
        // Arguments wiped before Procopticon saw the process: only the executable is known.
        XCTAssertEqual(r.commandLine, "/bin/node")
        XCTAssertTrue(r.argumentsOverwritten)
        // Seen before the retitle: the original command line.
        r.launchArguments = ["node", "server.js", "--port", "80"]
        XCTAssertEqual(r.commandLine, "node server.js --port 80")
        XCTAssertFalse(r.argumentsOverwritten)
        // Only argv[0] replaced (exec -a): the executable plus the remaining arguments.
        r.launchArguments = nil
        r.arguments = ["my-worker", "server.js", "--port", "80"]
        r.title = "my-worker"
        XCTAssertEqual(r.commandLine, "/bin/node server.js --port 80")
        XCTAssertFalse(r.argumentsOverwritten)
    }

    func testCustomTitleFollowsSymlinks() throws {
        let link = NSTemporaryDirectory() + "title-link-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/bin/ls")
        defer { try? FileManager.default.removeItem(atPath: link) }
        XCTAssertNil(ProcessRecord.customTitle(arguments: [link, "-l"], path: "/bin/ls", comm: "ls"))
    }
}
