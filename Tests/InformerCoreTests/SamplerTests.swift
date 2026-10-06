import XCTest
@testable import InformerCore

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
}
