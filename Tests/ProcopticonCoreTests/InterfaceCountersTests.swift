import XCTest
@testable import ProcopticonCore

final class InterfaceCountersTests: XCTestCase {
    func testGrowthHandlesWrapAndReset() {
        XCTAssertEqual(InterfaceCounters.growth(150, 100), 50)
        // Wrapped past 2^32.
        XCTAssertEqual(InterfaceCounters.growth(1000, UInt64(UInt32.max) - 999), 2000)
        // Restarted from zero (interface recreated).
        XCTAssertEqual(InterfaceCounters.growth(10, 5000), 10)
    }

    func testParsesNetstat() {
        let text = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0        16384 <Link#1>                       2621411     0 1527123421  2621411     0 1527123421     0
        lo0        16384 127           127.0.0.1        2621411     - 1527123421  2621411     - 1527123421     -
        en10       1500  <Link#23>   00:e0:4c:68:01:02 65887517     0 66396913365 35012416     0 3315191460     0
        gif0*      1280  <Link#2>                             0     0          0        0     0          0     0
        """
        let parsed = InterfaceCounters.parse(text)
        XCTAssertEqual(parsed["en10"], .init(bytesIn: 66_396_913_365, bytesOut: 3_315_191_460, packetsIn: 65_887_517, packetsOut: 35_012_416))
        XCTAssertEqual(parsed["lo0"]?.bytesIn, 1_527_123_421)
        XCTAssertEqual(parsed["gif0"], .init())
        XCTAssertEqual(parsed.count, 3)
    }

    func testNetstatRuns() throws {
        let totals = try XCTUnwrap(InterfaceCounters.netstat())
        XCTAssertNotNil(totals["lo0"])
    }
}
