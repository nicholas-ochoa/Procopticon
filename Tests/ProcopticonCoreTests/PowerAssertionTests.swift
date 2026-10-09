import XCTest
@testable import ProcopticonCore

final class PowerAssertionTests: XCTestCase {
    func testLegacyTypeAndTimeout() {
        let a = PowerAssertions.parse([
            "AssertType": "NoIdleSleepAssertion", "AssertionTrueType": "PreventUserIdleSystemSleep",
            "AssertName": "Electron", "AssertLevel": 255, "AssertPID": 63930, "AssertionId": 35362,
            "TimeoutSeconds": 0, "AssertStartWhen": Date(timeIntervalSince1970: 100),
        ], owner: 63930)
        XCTAssertEqual(a.type, "PreventUserIdleSystemSleep")
        XCTAssertEqual(a.requestedType, "NoIdleSleepAssertion")
        XCTAssertNil(a.timeout, "a zero timeout means none")
        XCTAssertEqual(a.sleepPrevention, .system)
        XCTAssertEqual(a.started, Date(timeIntervalSince1970: 100))
    }

    func testStrongestPreventionWins() {
        let system = PowerAssertions.parse(["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255], owner: 1)
        let display = PowerAssertions.parse(["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255, "TimeoutSeconds": 300,
                                             "AssertTimeoutTimeLeft": 120], owner: 1)
        let off = PowerAssertions.parse(["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 0], owner: 1)
        let active = PowerAssertions.parse(["AssertType": "UserIsActive", "AssertLevel": 255], owner: 1)
        XCTAssertEqual(display.timeLeft, 120)
        XCTAssertEqual([system, display].sleepPrevention, .display)
        XCTAssertEqual([system, off].sleepPrevention, .system)
        XCTAssertNil([active, off].sleepPrevention)
    }

    func testOnBehalfOfAnotherProcess() {
        let a = PowerAssertions.parse(["AssertType": "PreventUserIdleSystemSleep", "AssertPID": 300,
                                       "AssertionOnBehalfOfPID": 4242], owner: 300)
        XCTAssertEqual(a.ownerPid, 300)
        XCTAssertEqual(a.beneficiaryPid, 4242)
    }
}
