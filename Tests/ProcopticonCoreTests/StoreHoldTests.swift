import XCTest
@testable import ProcopticonCore

final class StoreHoldTests: XCTestCase {
    /// Spins the main run loop until `condition` holds or `timeout` passes.
    private func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testHeldUpdatesPublishWhenReleased() {
        let store = ProcessStore()
        store.refreshNow()
        XCTAssertTrue(wait(10) { store.revision > 0 }, "first sample never published")

        store.holdsUpdates = true
        let held = store.revision
        store.refreshNow()
        // The sample completes but stays held.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(store.revision, held)

        store.holdsUpdates = false
        XCTAssertGreaterThan(store.revision, held, "releasing should publish the held sample")
    }
}
