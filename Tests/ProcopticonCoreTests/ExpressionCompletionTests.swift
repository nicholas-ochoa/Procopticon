import XCTest
@testable import ProcopticonExpressions

final class ExpressionCompletionTests: XCTestCase {
    /// The names offered with the caret at "|", which is removed.
    private func names(_ marked: String, explicit: Bool = false) -> [String]? {
        let caret = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        return ExpressionCompletion.at(caret, in: text, explicit: explicit)?.items.map(\.name)
    }

    func testValuesByPrefixThenContaining() {
        XCTAssertEqual(names("cp|"), ["cpu", "cpuUser", "cpuKernel", "cpuTime"])
        XCTAssertEqual(names("x > 1 && mem|")?.prefix(3), ["memory", "memoryLimit", "peakMemory"])
        XCTAssertEqual(names("G|")?.prefix(3), ["GB", "group", "gpu"], "exact case first, then any case")
        XCTAssertEqual(names("Ma|")?.first, "Math")
    }

    func testWordAroundCaretIsReplaced() throws {
        let text = "cpu > 1 && memory > 2"
        let completion = try XCTUnwrap(ExpressionCompletion.at(13, in: text)) // "me|mory"
        XCTAssertEqual(completion.prefix, "me")
        XCTAssertEqual((text as NSString).substring(with: completion.range), "memory")
    }

    func testMembersAfterADot() {
        XCTAssertEqual(names("name.st|"), ["startsWith"])
        XCTAssertEqual(names("args.so|"), ["some"])
        XCTAssertEqual(names("args[0].len|"), ["length"])
        XCTAssertEqual(names("name.toLowerCase().inc|"), ["includes"])
        XCTAssertEqual(names("/safari/i.te|"), ["test"])
        XCTAssertEqual(names("Math.ma|"), ["max"])
        XCTAssertEqual(names("startTime.getH|"), ["getHours"])
        XCTAssertEqual(names("'abc'.ends|"), ["endsWith"])
        XCTAssertEqual(names("name.|")?.first, "length", "everything right after the dot")
        XCTAssertNil(names("foo.ba|"), "unknown type")
        XCTAssertNil(names("zombie.|"), "booleans have nothing worth completing")
    }

    func testNothingInLiteralsNumbersOrEmptyWords() {
        XCTAssertNil(names("name == \"cp|"))
        XCTAssertNil(names("cpu > 1 // mem|"))
        XCTAssertNil(names("/cp|/.test(name)"))
        XCTAssertNil(names("cpu > 5|"))
        XCTAssertNil(names("cpu > |"))
        XCTAssertNotNil(names("cpu > |", explicit: true), "asked for")
        XCTAssertNil(names("memoryLimit|"), "already complete")
        XCTAssertEqual(names("name == \"x\" && cp|")?.first, "cpu", "after a finished string")
    }

    func testInsertion() throws {
        let includes = try XCTUnwrap(ExpressionCompletion.at(7, in: "name.in")?.items.first)
        XCTAssertEqual(includes.label, "includes(text)")
        XCTAssertEqual(includes.insertion.text, "includes()")
        XCTAssertEqual(includes.insertion.caret, 9, "between the parentheses")
        let lower = try XCTUnwrap(ExpressionCompletion.at(9, in: "name.toLo")?.items.first)
        XCTAssertEqual(lower.insertion.text, "toLowerCase()")
        XCTAssertEqual(lower.insertion.caret, 13, "after them: no arguments")
        let cpu = try XCTUnwrap(ExpressionCompletion.at(2, in: "cp")?.items.first)
        XCTAssertEqual(cpu.insertion.text, "cpu")
        XCTAssertEqual(cpu.detail, "number")
    }
}
