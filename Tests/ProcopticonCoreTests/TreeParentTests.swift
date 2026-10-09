import XCTest
@testable import ProcopticonCore

final class TreeParentTests: XCTestCase {
    private func item(_ pid: Int32, ppid: Int32, responsible: Int32? = nil, start: Int64, exited: Bool = false) -> ProcessItem {
        var r = ProcessRecord(pid: pid, ppid: ppid, pgid: pid, uid: 501, ruid: 501, rgid: 20, svuid: 501, status: 2,
                              flags: 0, nice: 0, tty: 0, startMicros: start, comm: "p\(pid)")
        r.responsiblePid = responsible
        let state = ProcessState(record: r, time: 0, initial: true)
        if exited {
            state.markRemoved()
        }
        return ProcessItem(state)
    }

    func testResponsibleProcessForLaunchdChildren() {
        let kernel = item(0, ppid: 0, start: 0)
        let launchd = item(1, ppid: 0, start: 1)
        let teams = item(2925, ppid: 1, responsible: 2925, start: 10)
        let webView = item(2944, ppid: 2925, responsible: 2925, start: 11)
        let helper = item(2957, ppid: 2944, responsible: 2925, start: 12)
        let autoFill = item(3004, ppid: 1, responsible: 2925, start: 13)
        let daemon = item(500, ppid: 1, start: 5)
        let all = [kernel, launchd, teams, webView, helper, autoFill, daemon]
        let byPid = Dictionary(uniqueKeysWithValues: all.map { ($0.pid, $0) })
        func parent(_ i: ProcessItem) -> Int32? { ProcessStore.treeParent(of: i, in: byPid)?.pid }

        XCTAssertNil(parent(kernel))
        XCTAssertEqual(parent(launchd), 0)
        XCTAssertEqual(parent(teams), 1)
        XCTAssertEqual(parent(daemon), 1)
        // An XPC service launchd started for Teams goes under Teams.
        XCTAssertEqual(parent(autoFill), 2925)
        // A real parent other than launchd wins over the responsible process.
        XCTAssertEqual(parent(helper), 2944)
    }

    func testStaleResponsibleOrParentPid() {
        let launchd = item(1, ppid: 0, start: 1)
        // PID 700 was reused by a process that started after its "children".
        let reused = item(700, ppid: 1, start: 50)
        let service = item(800, ppid: 1, responsible: 700, start: 20)
        let orphan = item(801, ppid: 700, responsible: 700, start: 21)
        let byPid = Dictionary(uniqueKeysWithValues: [launchd, reused, service, orphan].map { ($0.pid, $0) })

        XCTAssertEqual(ProcessStore.treeParent(of: service, in: byPid)?.pid, 1)
        XCTAssertNil(ProcessStore.treeParent(of: orphan, in: byPid))
    }

    func testExitedProcessesKeepTheirPlace() {
        let launchd = item(1, ppid: 0, start: 1)
        let app = item(900, ppid: 1, start: 10, exited: true)
        let helper = item(901, ppid: 900, responsible: 900, start: 11, exited: true)
        // Still running after the app exited: launchd took it over, but it was the app's.
        let service = item(902, ppid: 1, responsible: 900, start: 12)
        let byPid = ProcessStore.treeIndex([launchd, app, helper, service])

        XCTAssertEqual(ProcessStore.treeParent(of: app, in: byPid)?.pid, 1)
        XCTAssertEqual(ProcessStore.treeParent(of: helper, in: byPid)?.pid, 900)
        XCTAssertEqual(ProcessStore.treeParent(of: service, in: byPid)?.pid, 900)
    }

    func testLiveProcessWinsAReusedPid() {
        let exited = item(950, ppid: 1, start: 20, exited: true)
        let live = item(950, ppid: 1, start: 30)
        XCTAssertFalse(ProcessStore.treeIndex([exited, live])[950]!.isRemoved)
        XCTAssertFalse(ProcessStore.treeIndex([live, exited])[950]!.isRemoved)
        // Between two live ones (a sampling race), the later start.
        let earlier = item(960, ppid: 1, start: 5)
        let later = item(960, ppid: 1, start: 6)
        XCTAssertEqual(ProcessStore.treeIndex([later, earlier])[960]!.record.startMicros, 6)
    }
}
