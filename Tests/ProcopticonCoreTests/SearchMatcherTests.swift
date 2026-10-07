import XCTest
@testable import ProcopticonCore

final class SearchMatcherTests: XCTestCase {
    func testEmptyMatchesEverything() {
        let m = SearchMatcher("   ")
        XCTAssertTrue(m.isEmpty)
        XCTAssertTrue(m.matches("anything"))
    }

    func testPlainSubstringIsCaseInsensitiveAndLiteral() {
        let m = SearchMatcher("finder")
        XCTAssertFalse(m.isRegex)
        XCTAssertTrue(m.matches("/System/Library/CoreServices/Finder.app"))
        XCTAssertFalse(SearchMatcher("a.c").matches("abc"), "plain text must not be treated as a pattern")
        XCTAssertTrue(SearchMatcher("a.c").matches("a.c"))
    }

    func testRegexModeCompilesWholeText() {
        let m = SearchMatcher("^mds(_stores)?$", regex: true)
        XCTAssertTrue(m.isRegex)
        XCTAssertTrue(m.matches("mds"))
        XCTAssertTrue(m.matches("MDS_STORES"))
        XCTAssertFalse(m.matches("mdworker"))
    }

    func testSlashSyntaxWorksWithoutRegexMode() {
        let m = SearchMatcher("/^com\\.apple\\.(Finder|Dock)$/")
        XCTAssertTrue(m.isRegex)
        XCTAssertTrue(m.matches("com.apple.finder"))
        XCTAssertFalse(m.matches("com.apple.finderx"))
    }

    func testCaseSensitiveFlag() {
        let m = SearchMatcher("/Safari/c")
        XCTAssertTrue(m.matches("Safari"))
        XCTAssertFalse(m.matches("safari"))
    }

    func testPathsAreNotMistakenForRegex() {
        // A path has a trailing component after the last slash that isn't a flag set.
        let m = SearchMatcher("/usr/lib")
        XCTAssertFalse(m.isRegex)
        XCTAssertTrue(m.matches("/usr/lib/dyld"))
        let tmp = SearchMatcher("/tmp/")
        XCTAssertTrue(tmp.isRegex)
        XCTAssertTrue(tmp.matches("/private/tmp"))
    }

    func testInvalidRegexReportsErrorAndMatchesNothing() {
        let m = SearchMatcher("foo(", regex: true)
        XCTAssertFalse(m.isValid)
        XCTAssertNotNil(m.error)
        XCTAssertFalse(m.matches("foo("))
    }

    func testIdentifierMatching() {
        XCTAssertTrue(SearchMatcher("12").matchesIdentifier("12"))
        XCTAssertFalse(SearchMatcher("12").matchesIdentifier("123"))
        XCTAssertTrue(SearchMatcher("^1\\d{2}$", regex: true).matchesIdentifier("123"))
    }

    func testOpenFileSearchHonorsRegex() {
        let hits = ProcessDetails.searchOpenFiles(query: "^/dev/(null|tty)", includeLibraries: false, regex: true)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.name.hasPrefix("/dev/null") || $0.name.hasPrefix("/dev/tty") })
        XCTAssertTrue(ProcessDetails.searchOpenFiles(query: "foo(", includeLibraries: false, regex: true).isEmpty)
    }
}
