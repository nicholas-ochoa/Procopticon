import Darwin
import XCTest
@testable import ProcopticonCore

final class TrustedHelperTests: XCTestCase {
    func testRequirementNamesTheTeamAndTheHelper() {
        XCTAssertEqual(
            TrustedHelper.requirement(team: "ABCDE12345", appIdentifier: "com.example.App"),
            "anchor apple generic and identifier \"com.example.App.helper\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    func testRequirementRefusesValuesASignatureCannotHave() {
        XCTAssertNil(TrustedHelper.requirement(team: "", appIdentifier: "com.example.App"))
        XCTAssertNil(TrustedHelper.requirement(team: "ABC\" or anchor apple", appIdentifier: "com.example.App"))
        XCTAssertNil(TrustedHelper.requirement(team: "ABCDE12345", appIdentifier: "com.example\" or \"x"))
        XCTAssertNil(TrustedHelper.requirement(team: "ABCDE12345", appIdentifier: ""))
    }

    func testStartScriptRunsTheCheckedCopyNotTheBundledHelper() {
        let helper = "/Applications/Some App.app/Contents/MacOS/procopticon-helper"
        let script = TrustedHelper.startScript(helper: helper, clientPid: 4321, clientUid: 501, requirement: "anchor apple generic")
        let copy = "/var/run/procopticon/helper-4321"
        let steps = script.components(separatedBy: "; ")
        // The bundled helper is only ever copied.
        XCTAssertTrue(script.contains("/usr/bin/head -c 67108864 '\(helper)' > \(copy) && /bin/chmod 700 \(copy)"))
        // Nobody but root may read the copy at any point: it may not be the helper at all.
        XCTAssertTrue(script.hasPrefix("umask 077; "))
        XCTAssertFalse(script.contains("chmod 755 \(copy)"))
        XCTAssertEqual(steps.last, "\(copy) --serve --client-pid 4321 --client-uid 501 >/dev/null 2>&1 &")
        XCTAssertFalse(steps.contains { $0.hasPrefix("'\(helper)'") })
        // The signature check comes after the copy and before the copy runs.
        let copied = try? XCTUnwrap(steps.firstIndex { $0.hasPrefix("/usr/bin/head") })
        let checked = try? XCTUnwrap(steps.firstIndex { $0.contains("/usr/bin/codesign --verify --strict '-R=anchor apple generic' \(copy)") })
        XCTAssertNotNil(copied)
        XCTAssertNotNil(checked)
        if let copied, let checked {
            XCTAssertLessThan(copied, checked)
            XCTAssertLessThan(checked, steps.count - 1)
        }
    }

    func testStartScriptWithoutATeamSkipsOnlyTheSignatureCheck() {
        let script = TrustedHelper.startScript(helper: "/tmp/helper", clientPid: 7, clientUid: 501, requirement: nil)
        XCTAssertFalse(script.contains("codesign"))
        XCTAssertTrue(script.contains("/usr/bin/head -c 67108864 /tmp/helper > /var/run/procopticon/helper-7"))
        XCTAssertTrue(script.hasSuffix("/var/run/procopticon/helper-7 --serve --client-pid 7 --client-uid 501 >/dev/null 2>&1 &"))
    }

    func testOnlyRootOwnedFilesInRootOwnedDirectoriesAreTrusted() throws {
        XCTAssertTrue(TrustedHelper.isRootOnly("/bin/ls"))
        let file = NSTemporaryDirectory() + "trusted-\(UUID().uuidString)"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        XCTAssertFalse(TrustedHelper.isRootOnly(file))
        XCTAssertFalse(TrustedHelper.isRootOnly("/nonexistent/file"))
        // A directory, and a link to a trusted file, are not files only root can change.
        XCTAssertFalse(TrustedHelper.isRootOnly("/bin"))
        let link = NSTemporaryDirectory() + "trusted-link-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/bin/ls")
        defer { try? FileManager.default.removeItem(atPath: link) }
        XCTAssertFalse(TrustedHelper.isRootOnly(link))
    }

    func testReportComesBackAsTextAndLeavesNothingBehind() throws {
        let before = try reportDirectories()
        let out = ToolReport.run("/bin/sh", ["-c", "echo \"$0\" > \"$0\"; echo printed", ToolReport.placeholder])
        XCTAssertEqual(out.status, 0)
        // The tool was handed a file named report.txt in a directory of its own, and wrote there.
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasSuffix("/report.txt"), path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try reportDirectories(), before)
    }

    func testPrivateDirectoryIsOnlyForItsOwner() throws {
        let directory = try XCTUnwrap(ToolReport.makePrivateDirectory())
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var st = stat()
        XCTAssertEqual(lstat(directory, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(st.st_uid, getuid())
    }

    func testToolThatWritesNoReportReturnsWhatItPrinted() {
        let out = ToolReport.run("/bin/sh", ["-c", "echo printed; exit 3", ToolReport.placeholder])
        XCTAssertEqual(out.status, 3)
        XCTAssertEqual(out.stdout, "printed\n")
    }

    private func reportDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("report.") }.sorted()
    }
}
