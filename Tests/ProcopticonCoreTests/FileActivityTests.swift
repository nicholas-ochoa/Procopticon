import XCTest
@testable import ProcopticonCore

final class FileActivityTests: XCTestCase {
    func testSystemCalls() throws {
        let open = try XCTUnwrap(FileActivity.parse("12:22:27.092977  open              F=3        (_WC_T__________)  out.txt                                                                    0.000061   zsh.23497470", id: 1))
        XCTAssertEqual(open.time, "12:22:27.092977")
        XCTAssertEqual(open.call, "open")
        XCTAssertEqual(open.descriptor, 3)
        XCTAssertEqual(open.path, "out.txt")
        XCTAssertEqual(open.details, "(_WC_T__________)")
        XCTAssertEqual(open.duration, 0.000061, accuracy: 1e-9)
        XCTAssertEqual(open.command, "zsh")
        XCTAssertEqual(open.thread, "23497470")
        XCTAssertFalse(open.waited)

        let read = try XCTUnwrap(FileActivity.parse("12:22:27.077987  read              F=3    B=0x8                                              0.000131   zsh.23497470", id: 2))
        XCTAssertEqual(read.bytes, 8)
        XCTAssertEqual(read.path, "")
        XCTAssertTrue(read.isRead)

        let failed = try XCTUnwrap(FileActivity.parse("12:22:27.100000  stat64            [  2]           /nonexistent                          0.000010   ls.12345", id: 3))
        XCTAssertEqual(failed.errorNumber, 2)
        XCTAssertEqual(failed.path, "/nonexistent")
        XCTAssertEqual(failed.errorDescription, String(cString: strerror(2)))

        let fcntl = try XCTUnwrap(FileActivity.parse("12:22:27.092978  fcntl             F=1   <DUPFD>                                               0.000001   zsh.23497470", id: 4))
        XCTAssertEqual(fcntl.details, "<DUPFD>")
    }

    func testDiskIOWithSpacesInPathAndProcess() throws {
        let line = "12:22:08.266666    WrData[S]       D=0x063114eb  B=0x1000   /dev/disk3s5  /Users/me/Library/Caches/Profile 3/Cache_Data/365f_0                0.000025 W Google Chrome He.20770246"
        let e = try XCTUnwrap(FileActivity.parse(line, id: 5))
        XCTAssertEqual(e.call, "WrData[S]")
        XCTAssertTrue(e.isDiskIO)
        XCTAssertTrue(e.isWrite)
        XCTAssertEqual(e.bytes, 0x1000)
        XCTAssertEqual(e.path, "/Users/me/Library/Caches/Profile 3/Cache_Data/365f_0")
        XCTAssertEqual(e.details, "D=0x063114eb /dev/disk3s5")
        XCTAssertTrue(e.waited)
        XCTAssertEqual(e.command, "Google Chrome He")
        XCTAssertTrue(FileActivity.command(e.command, matches: "Google Chrome Helper (Renderer)"))
        XCTAssertFalse(FileActivity.command(e.command, matches: "Finder"))
        XCTAssertNil(FileActivity.parse("TIMESTAMP   CALL   FILENAME", id: 0))
    }

    func testDescriptorsNameTheirFiles() throws {
        var tracker = FileActivityTracker(openFiles: [5: "/etc/hosts"])
        var read = try XCTUnwrap(FileActivity.parse("12:00:00.000001  read  F=5  B=0x10   0.000001   cat.1", id: 1))
        tracker.track(&read)
        XCTAssertEqual(read.path, "/etc/hosts")
        XCTAssertTrue(read.pathFromDescriptor)
        var open = try XCTUnwrap(FileActivity.parse("12:00:00.000002  open  F=6  (R_____)  /tmp/a b.txt   0.000001   cat.1", id: 2))
        tracker.track(&open)
        var write = try XCTUnwrap(FileActivity.parse("12:00:00.000003  write  F=6  B=0x20   0.000001   cat.1", id: 3))
        tracker.track(&write)
        XCTAssertEqual(write.path, "/tmp/a b.txt")
        var close = try XCTUnwrap(FileActivity.parse("12:00:00.000004  close  F=6   0.000001   cat.1", id: 4))
        tracker.track(&close)
        XCTAssertEqual(close.path, "/tmp/a b.txt")
        var after = try XCTUnwrap(FileActivity.parse("12:00:00.000005  read  F=6  B=0x20   0.000001   cat.1", id: 5))
        tracker.track(&after)
        XCTAssertEqual(after.path, "", "the descriptor was closed")

        var summary = FileActivitySummary(path: "/tmp/a b.txt")
        summary.add(write)
        XCTAssertEqual(summary.bytesWritten, 0x20)
        XCTAssertEqual(summary.calls, 1)
    }
}
