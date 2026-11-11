import XCTest
@testable import ProcopticonCore

final class ScrollAxisLockTests: XCTestCase {
    /// A plain wheel's events belong to no gesture, so neither wheel ever holds the other back.
    func testPlainWheelsAreNeverLocked() {
        var lock = ScrollAxisLock()
        for i in 0..<20 {
            XCTAssertNil(lock.axis(deltaX: 0, deltaY: 3, inGesture: false, begins: false, timestamp: Double(i) * 0.01))
        }
        XCTAssertNil(lock.axis(deltaX: 3, deltaY: 0, inGesture: false, begins: false, timestamp: 0.21))
    }

    func testGestureKeepsTheAxisItStartedAlong() {
        var lock = ScrollAxisLock()
        XCTAssertEqual(lock.axis(deltaX: 1, deltaY: 8, inGesture: true, begins: true, timestamp: 0), .vertical)
        // A later sideways drift, and the momentum after the fingers lift, stay vertical.
        XCTAssertEqual(lock.axis(deltaX: 20, deltaY: 1, inGesture: true, begins: false, timestamp: 0.01), .vertical)
        XCTAssertEqual(lock.axis(deltaX: 5, deltaY: 0, inGesture: true, begins: false, timestamp: 0.02), .vertical)
    }

    /// The first events of a swipe are too small to decide on: a stray point sideways at the
    /// start of a vertical swipe mustn't make the whole swipe horizontal.
    func testAxisIsSettledOnlyAfterSomeDistance() {
        var lock = ScrollAxisLock()
        XCTAssertEqual(lock.axis(deltaX: 1, deltaY: 0, inGesture: true, begins: true, timestamp: 0), .horizontal)
        XCTAssertEqual(lock.axis(deltaX: 0, deltaY: 4, inGesture: true, begins: false, timestamp: 0.01), .vertical)
        XCTAssertEqual(lock.axis(deltaX: 0, deltaY: 4, inGesture: true, begins: false, timestamp: 0.02), .vertical)
        XCTAssertEqual(lock.axis(deltaX: 30, deltaY: 0, inGesture: true, begins: false, timestamp: 0.03), .vertical)
    }

    /// The bug this replaces AppKit's lock for: one wheel after the other, as gestures.
    func testNewGestureChoosesAgain() {
        var lock = ScrollAxisLock()
        XCTAssertEqual(lock.axis(deltaX: 0, deltaY: 10, inGesture: true, begins: true, timestamp: 0), .vertical)
        XCTAssertEqual(lock.axis(deltaX: 0, deltaY: 10, inGesture: true, begins: false, timestamp: 0.01), .vertical)
        XCTAssertEqual(lock.axis(deltaX: 10, deltaY: 0, inGesture: true, begins: true, timestamp: 0.05), .horizontal)
        XCTAssertEqual(lock.axis(deltaX: 0, deltaY: 10, inGesture: true, begins: true, timestamp: 0.10), .vertical)
    }

    /// Events that never say a gesture began or ended can't hold the axis past a pause.
    func testLockExpiresWhenEventsPause() {
        var lock = ScrollAxisLock()
        XCTAssertEqual(lock.axis(deltaX: 0, deltaY: 10, inGesture: true, begins: false, timestamp: 0), .vertical)
        XCTAssertEqual(lock.axis(deltaX: 10, deltaY: 0, inGesture: true, begins: false, timestamp: 0.2), .vertical)
        XCTAssertEqual(lock.axis(deltaX: 10, deltaY: 0, inGesture: true, begins: false, timestamp: 1.0), .horizontal)
    }

    func testPlainWheelAfterGestureIsFree() {
        var lock = ScrollAxisLock()
        XCTAssertEqual(lock.axis(deltaX: 0, deltaY: 10, inGesture: true, begins: true, timestamp: 0), .vertical)
        XCTAssertNil(lock.axis(deltaX: 3, deltaY: 0, inGesture: false, begins: false, timestamp: 0.01))
        // And the gesture's choice is gone with it.
        XCTAssertEqual(lock.axis(deltaX: 10, deltaY: 0, inGesture: true, begins: false, timestamp: 0.02), .horizontal)
    }

    func testEventWithoutMovementAllowsBoth() {
        var lock = ScrollAxisLock()
        XCTAssertNil(lock.axis(deltaX: 0, deltaY: 0, inGesture: true, begins: true, timestamp: 0))
    }
}
