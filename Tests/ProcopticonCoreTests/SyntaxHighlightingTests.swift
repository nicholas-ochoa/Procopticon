import XCTest
@testable import ProcopticonCore

final class SyntaxHighlightingTests: XCTestCase {
    /// Tokens as "kind:text", in order.
    private func spans(_ text: String, _ mode: SearchMode) -> [String] {
        let ns = text as NSString
        return SyntaxHighlighting.tokens(text, mode: mode, fields: ["cpu", "name", "path", "args", "memory"], constants: ["GB"])
            .map { "\($0.kind):\(ns.substring(with: $0.range))" }
    }

    func testJavaScriptTokens() {
        XCTAssertEqual(spans("cpu > 50 && name.includes(\"Safari\") // busy", .javascript), [
            "field:cpu", "number:50", "field:name", "property:includes", "string:\"Safari\"", "comment:// busy",
        ])
        XCTAssertEqual(spans("memory > 2 * GB && typeof x === 'string'", .javascript), [
            "field:memory", "number:2", "constant:GB", "keyword:typeof", "string:'string'",
        ])
        XCTAssertEqual(spans("args[0].length >= 0x1F && !false", .javascript), [
            "field:args", "number:0", "property:length", "number:0x1F", "keyword:false",
        ])
        XCTAssertEqual(spans("1.5e-3 + .5", .javascript), ["number:1.5e-3", "number:.5"])
        XCTAssertEqual(spans("/* a\nb */ cpu", .javascript), ["comment:/* a\nb */", "field:cpu"])
    }

    func testRegexLiteralsAndDivision() {
        // A slash after a value divides; after an operator or "(" it starts a regex literal.
        XCTAssertEqual(spans("cpu / 2 / 3", .javascript), ["field:cpu", "number:2", "number:3"])
        XCTAssertEqual(spans("/safari/i.test(name)", .javascript), [
            "string:/safari/i", "regexDelimiter:/", "regexDelimiter:/i", "property:test", "field:name",
        ])
        XCTAssertEqual(spans("(/^com\\.apple\\./).test(path)", .javascript), [
            "string:/^com\\.apple\\./", "regexDelimiter:/", "regexAnchor:^", "regexEscape:\\.", "regexEscape:\\.", "regexDelimiter:/",
            "property:test", "field:path",
        ])
        // A slash inside a class doesn't end the literal; "//" inside a string isn't a comment.
        XCTAssertEqual(spans("/[/]x/.test(path) && path != \"//\"", .javascript), [
            "string:/[/]x/", "regexDelimiter:/", "regexClass:[/]", "regexDelimiter:/", "property:test", "field:path", "field:path",
            "string:\"//\"",
        ])
        // An unterminated literal is just a slash.
        XCTAssertEqual(spans("cpu > /x", .javascript), ["field:cpu"])
    }

    func testRegexTokens() {
        XCTAssertEqual(spans("^(Safari|Mail)\\d+[a-z\\s]*?$", .regex), [
            "regexAnchor:^", "regexGroup:(", "regexAlternation:|", "regexGroup:)", "regexEscape:\\d",
            "regexQuantifier:+", "regexClass:[a-z\\s]", "regexEscape:\\s", "regexQuantifier:*?", "regexAnchor:$",
        ])
        XCTAssertEqual(spans("(?:a|b){2,5}(?<name>x)(?=y)\\bz.", .regex), [
            "regexGroup:(?:", "regexAlternation:|", "regexGroup:)", "regexQuantifier:{2,5}", "regexGroup:(?<name>",
            "regexGroup:)", "regexGroup:(?=", "regexGroup:)", "regexAnchor:\\b", "regexWildcard:.",
        ])
        XCTAssertEqual(spans("a{x}\\x41\\p{L}", .regex), ["regexEscape:\\x41", "regexEscape:\\p{L}"], "a literal brace")
    }

    func testRegexMistakes() {
        XCTAssertEqual(spans("(a|b", .regex), ["error:(", "regexAlternation:|"])
        XCTAssertEqual(spans("a)", .regex), ["error:)"])
        XCTAssertEqual(spans("*a", .regex), ["error:*"])
        XCTAssertEqual(spans("(+)", .regex), ["regexGroup:(", "error:+", "regexGroup:)"])
        XCTAssertEqual(spans("[abc", .regex), ["regexClass:[abc", "error:["])
        XCTAssertEqual(spans("ab\\", .regex), ["error:\\"])
    }

    func testPlainTextColorsOnlySlashPatterns() {
        XCTAssertEqual(spans("safari helper", .text), [])
        XCTAssertEqual(spans("/usr/lib", .text), [], "a path isn't a pattern")
        XCTAssertEqual(spans("  /^mds(_stores)?$/c", .text), [
            "regexDelimiter:/", "regexAnchor:^", "regexGroup:(", "regexGroup:)", "regexQuantifier:?", "regexAnchor:$",
            "regexDelimiter:/c",
        ])
    }

    func testNonASCIIRangesAreUTF16() {
        let text = "name == \"Café 🚀\" && cpu > 1"
        let tokens = SyntaxHighlighting.tokens(text, mode: .javascript, fields: ["name", "cpu"])
        XCTAssertEqual(tokens.map { (text as NSString).substring(with: $0.range) }, ["name", "\"Café 🚀\"", "cpu", "1"])
    }
}
