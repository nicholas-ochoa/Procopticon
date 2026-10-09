import XCTest
@testable import ProcopticonCore

final class ExportFormattingTests: XCTestCase {
    private let table = ExportTable(
        columns: [.init(title: "Name", unit: nil), .init(title: "PID", unit: nil), .init(title: "CPU", unit: "%"),
                  .init(title: "Memory", unit: "bytes"), .init(title: "Command line", unit: nil)],
        rows: [
            [.string("Safari"), .integer(123), .number(12.5), .integer(1_073_741_824), .string(#"/App "x", y"#)],
            [.string("kernel_task"), .integer(0), .number(0), .null, .null],
        ])

    func testJSONKeepsTypesAndOrder() throws {
        let text = ExportFormatting.json(table, root: "processes", date: Date(timeIntervalSince1970: 0))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["exported"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(object["units"] as? [String: String], ["CPU": "%", "Memory": "bytes"])
        let rows = try XCTUnwrap(object["processes"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["Name"] as? String, "Safari")
        XCTAssertEqual(rows[0]["PID"] as? Int, 123)
        XCTAssertEqual(rows[0]["CPU"] as? Double, 12.5)
        XCTAssertEqual(rows[0]["Memory"] as? Int, 1_073_741_824)
        XCTAssertEqual(rows[0]["Command line"] as? String, #"/App "x", y"#)
        XCTAssertTrue(rows[1]["Memory"] is NSNull)
        // Keys stay in column order.
        let first = try XCTUnwrap(text.range(of: "\"Name\""))
        let last = try XCTUnwrap(text.range(of: "\"Command line\""))
        XCTAssertLessThan(first.lowerBound, last.lowerBound)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(ExportFormatting.json(ExportTable(columns: table.columns, rows: []), root: "processes").utf8)))
    }

    func testCSVQuotesAndUnits() {
        let lines = ExportFormatting.csv(table).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Name,PID,CPU (%),Memory (bytes),Command line")
        XCTAssertEqual(lines[1], #"Safari,123,12.5,1073741824,"/App ""x"", y""#)
        XCTAssertEqual(lines[2], "kernel_task,0,0,,")
    }

    func testValuesFromCells() {
        XCTAssertEqual(ExportValue(UInt64(5), text: "5 B"), .integer(5))
        XCTAssertEqual(ExportValue(Int32(-1), text: ""), .integer(-1))
        XCTAssertEqual(ExportValue(2.5, text: "2.50"), .number(2.5))
        XCTAssertEqual(ExportValue(Double.infinity, text: ""), .null)
        XCTAssertEqual(ExportValue("x", text: "x"), .string("x"))
        XCTAssertEqual(ExportFormatting.quote("a\"b\\c\n\u{1}"), #""a\"b\\c\n\u0001""#)
    }
}
