import XCTest
@testable import ProcopticonCore

final class NetworkUsageTests: XCTestCase {
    func testParsesNettopCSV() {
        let text = """
        ,packets_in,bytes_in,packets_out,bytes_out,
        kernel_task.0,631695,1040183005,781053,203866440,
        launchd.1,0,0,0,0,
        Google Chrome Helper (Renderer).11453,10,2000,5,300,
        odd, name.v2.42,1,2,3,4,
        ,comma first.77,5,6,7,8,
        after.78,1,1,1,1,

        """
        let parsed = NetworkUsage.parse(text)
        XCTAssertEqual(parsed[0], NetworkCounters(bytesIn: 1_040_183_005, bytesOut: 203_866_440, packetsIn: 631_695, packetsOut: 781_053))
        XCTAssertEqual(parsed[1], NetworkCounters())
        XCTAssertEqual(parsed[11453], NetworkCounters(bytesIn: 2000, bytesOut: 300, packetsIn: 10, packetsOut: 5))
        XCTAssertEqual(parsed[42], NetworkCounters(bytesIn: 2, bytesOut: 4, packetsIn: 1, packetsOut: 3))
        // A name starting with a comma is a row, not a new header that hides the rows after it.
        XCTAssertEqual(parsed[77], NetworkCounters(bytesIn: 6, bytesOut: 8, packetsIn: 5, packetsOut: 7))
        XCTAssertEqual(parsed[78], NetworkCounters(bytesIn: 1, bytesOut: 1, packetsIn: 1, packetsOut: 1))
    }

    func testParsesTimeColumnHeader() {
        let text = """
        time,,bytes_in,bytes_out,
        15:03:36.826314,apsd.386,212160,279700,
        """
        XCTAssertEqual(NetworkUsage.parse(text)[386], NetworkCounters(bytesIn: 212_160, bytesOut: 279_700))
    }

    func testSampleRunsNettop() throws {
        let sample = try XCTUnwrap(NetworkUsage.sample())
        // The kernel always reports itself.
        XCTAssertNotNil(sample[0])
        print("processes with network counters:", sample.count)
    }
}
