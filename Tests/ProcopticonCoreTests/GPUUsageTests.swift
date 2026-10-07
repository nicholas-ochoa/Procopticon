import XCTest
@testable import ProcopticonCore

final class GPUUsageTests: XCTestCase {
    func testCreatorParsing() {
        XCTAssertEqual(GPUUsage.pid(fromCreator: "pid 416, WindowServer"), 416)
        XCTAssertEqual(GPUUsage.pid(fromCreator: "pid 7"), 7)
        XCTAssertNil(GPUUsage.pid(fromCreator: "WindowServer"))
        XCTAssertNil(GPUUsage.pid(fromCreator: "pid , x"))
    }

    func testAppUsageTotal() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 4_449_729_493_875 as UInt64)],
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 27_984_333)],
            ["API": "Metal"],
        ]
        XCTAssertEqual(GPUUsage.gpuTime(appUsage: usage), 4_449_757_478_208)
    }

    func testSampleReadsRegistry() {
        // Smoke test: reading the registry works without privileges (may be empty in a VM).
        let times = GPUUsage.sample()
        print("processes with GPU connections:", times.count)
    }
}
