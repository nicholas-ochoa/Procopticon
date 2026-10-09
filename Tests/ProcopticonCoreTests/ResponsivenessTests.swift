import XCTest
@testable import ProcopticonCore

final class ResponsivenessTests: XCTestCase {
    private func state() -> ProcessState {
        let r = ProcessRecord(pid: 42, ppid: 1, pgid: 42, uid: 501, ruid: 501, rgid: 20, svuid: 501, status: 2,
                              flags: 0, nice: 0, tty: 0, startMicros: 1, comm: "App")
        return ProcessState(record: r, time: 0, initial: true)
    }

    func testTransitionsAreReportedOnce() {
        let s = state()
        XCTAssertFalse(s.updateResponding(nil), "not an application")
        XCTAssertFalse(s.updateResponding(true), "responding from the start")
        XCTAssertNil(s.notRespondingSince)

        XCTAssertTrue(s.updateResponding(false), "stopped responding")
        let since = s.notRespondingSince
        XCTAssertNotNil(since)
        XCTAssertFalse(s.updateResponding(false), "still hung")
        XCTAssertEqual(s.notRespondingSince, since, "the start of the hang is kept")
        XCTAssertFalse(ProcessItem(s).responding ?? true)
        XCTAssertTrue(ProcessItem(s).isNotResponding)

        XCTAssertTrue(s.updateResponding(true), "responding again")
        XCTAssertNil(s.notRespondingSince)
        XCTAssertFalse(ProcessItem(s).isNotResponding)
    }

    func testHungWhenFirstSeen() {
        let s = state()
        XCTAssertTrue(s.updateResponding(false))
        XCTAssertNotNil(s.notRespondingSince)
    }

    func testExitClearsTheHang() {
        let s = state()
        _ = s.updateResponding(false)
        s.markRemoved()
        XCTAssertNil(s.responding)
        XCTAssertNil(s.notRespondingSince)
    }

    func testUnknownProcessesCountAsResponding() {
        // PIDs that aren't applications (or don't exist) are never reported as hung.
        XCTAssertTrue(AppResponsiveness.unresponsive(among: [0, 1, 999_999]).isEmpty)
    }
}
