import CSysInfo
import XCTest
@testable import ProcopticonCore

final class MemoryColumnsTests: XCTestCase {
    func testPortCountsAcrossChunks() {
        let text = """
        Process (0) : kernel_task
          name      ipc-object    rights     flags   boost  reqs  recv  send sonce oref  qlimit  msgcount  context            identifier  type
        ---------   ----------  ----------  -------- -----  ---- ----- ----- ----- ----  ------  --------  ------------------ ----------- ------------

        total     = 0
        SEND      = 0
        Process (1) : launchd
        0x00000103  0xd9b700f0  send        --------        ---            2                                                  0x00000000  THREAD-CONTROL (0x1bd5)
        total     = 6016
        Process (359) : powerd
        total     = 165

        """
        var parser = MachPorts.Parser()
        // Odd-sized pieces, so lines are split across feeds.
        let data = Data(text.utf8)
        var i = 0
        while i < data.count {
            parser.feed(data[i..<min(i + 37, data.count)])
            i += 37
        }
        XCTAssertEqual(parser.counts, [0: 0, 1: 6016, 359: 165])
    }

    func testOwnProcessMemoryDetails() {
        var s = si_task_stats()
        XCTAssertEqual(si_task_stats_for_pid(getpid(), &s), 0)
        XCTAssertEqual(s.hasVmInfo, 1, "the name port of our own task is always available")
        let stats = TaskStats(s)
        XCTAssertNotNil(stats.compressed)
        XCTAssertNotNil(stats.purgeable)
    }

    func testJetsamNeedsRoot() {
        var list: UnsafeMutablePointer<si_jetsam_entry>?
        let n = si_jetsam_list(&list)
        if geteuid() == 0 {
            XCTAssertGreaterThan(n, 0)
        } else {
            XCTAssertLessThan(n, 0)
        }
        free(list)
    }
}
