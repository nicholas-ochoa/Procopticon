import XCTest
@testable import ProcopticonCore

final class QuarantineTests: XCTestCase {
    func testParseFlag() {
        let q = Quarantine.parse("01c1;6ac5c447;Chrome;80FAB5E3-548A-46D3-B2C7-1BE210A5F3AD")
        XCTAssertEqual(q.flags, 0x01c1)
        XCTAssertTrue(q.isApproved)
        XCTAssertFalse(q.isFromSandbox)
        XCTAssertEqual(q.agent, "Chrome")
        XCTAssertEqual(q.date, Date(timeIntervalSince1970: 0x6ac5c447))
        XCTAssertEqual(q.eventIdentifier, "80FAB5E3-548A-46D3-B2C7-1BE210A5F3AD")
        let bare = Quarantine.parse("0181;6a9756d8;;")
        XCTAssertFalse(bare.isApproved)
        XCTAssertNil(bare.agent)
        XCTAssertNil(bare.eventIdentifier)
        XCTAssertTrue(bare.sourceDescription.hasPrefix("Downloaded on "))
    }

    func testReadsAttributesOfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quarantine-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(Quarantine.info(path: url.path), "not quarantined")
        let flag = "0083;6ac5c447;Safari;"
        XCTAssertEqual(setxattr(url.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0), 0)
        let froms = try PropertyListSerialization.data(fromPropertyList: ["https://example.com/app.zip", "https://example.com/"], format: .binary, options: 0)
        _ = froms.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, froms.count, 0, 0) }
        let q = try XCTUnwrap(Quarantine.info(path: url.path))
        XCTAssertEqual(q.agent, "Safari")
        XCTAssertEqual(q.downloadURL, "https://example.com/app.zip")
        XCTAssertEqual(q.pageURL, "https://example.com/")
        XCTAssertEqual(q.url, "https://example.com/app.zip")
    }
}
