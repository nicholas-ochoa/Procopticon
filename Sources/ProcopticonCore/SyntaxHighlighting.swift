import Foundation

/// A span of filter text to color, in UTF-16 offsets (as NSString and NSTextStorage count them).
public struct SyntaxToken: Equatable {
    public enum Kind: Equatable {
        // JavaScript
        case keyword, string, number, comment
        /// A process value, such as `cpu`.
        case field
        /// A constant the engine defines, such as `GB`.
        case constant
        /// A property or method after a dot, such as `includes`.
        case property
        // Regular expressions (also inside JavaScript regex literals)
        /// The slashes around a regex literal or /pattern/, and its flags.
        case regexDelimiter
        case regexEscape, regexClass, regexGroup, regexQuantifier, regexAnchor, regexAlternation, regexWildcard
        /// Something that can't be right: a parenthesis that closes nothing or is never closed, a
        /// quantifier with nothing to repeat, an unfinished class or escape.
        case error
    }

    public var range: NSRange
    public var kind: Kind

    public init(_ location: Int, _ length: Int, _ kind: Kind) {
        range = NSRange(location: location, length: length)
        self.kind = kind
    }
}

/// Tokenizers for coloring filter text. They accept any text, however broken, and only go as far
/// as coloring needs; they don't validate (the matcher reports errors). A later token may lie
/// inside an earlier one, such as an escape inside a character class, and then takes precedence.
public enum SyntaxHighlighting {
    /// Tokens for filter text in `mode`. For JavaScript, `fields` and `constants` are the names to
    /// color as the process's values and as constants.
    public static func tokens(_ text: String, mode: SearchMode, fields: Set<String> = [],
                              constants: Set<String> = []) -> [SyntaxToken] {
        let units = Array(text.utf16)
        switch mode {
        case .text:
            return slashDelimitedTokens(units)
        case .regex:
            var tokens: [SyntaxToken] = []
            regex(units, 0..<units.count, into: &tokens)
            return tokens
        case .javascript:
            return javascript(units, fields: fields, constants: constants)
        }
    }

    // MARK: Plain text

    /// In plain text, `/pattern/` (with optional flags) is a regular expression; see `SearchMatcher`.
    private static func slashDelimitedTokens(_ u: [UInt16]) -> [SyntaxToken] {
        var start = 0
        var end = u.count
        while start < end, u[start] == space || u[start] == tab { start += 1 }
        while end > start, u[end - 1] == space || u[end - 1] == tab { end -= 1 }
        let trimmed = String(utf16CodeUnits: Array(u[start..<end]), count: end - start)
        guard let (body, flags) = SearchMatcher.slashDelimited(trimmed) else { return [] }
        let bodyEnd = start + 1 + body.utf16.count
        var tokens = [SyntaxToken(start, 1, .regexDelimiter)]
        regex(u, (start + 1)..<bodyEnd, into: &tokens)
        tokens.append(SyntaxToken(bodyEnd, 1 + flags.utf16.count, .regexDelimiter))
        return tokens
    }

    // MARK: JavaScript

    private static let keywords: Set<String> = [
        "typeof", "instanceof", "in", "of", "new", "delete", "void", "this", "function", "return", "if", "else",
        "var", "let", "const", "true", "false", "null", "undefined", "NaN", "Infinity",
    ]
    /// Keywords after which a "/" starts a regex literal rather than dividing.
    private static let operatorKeywords: Set<String> = ["typeof", "instanceof", "in", "of", "new", "delete", "void", "return"]

    private static func javascript(_ u: [UInt16], fields: Set<String>, constants: Set<String>) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var i = 0
        let n = u.count
        // Whether a "/" here would start a regex literal: at the start, and after an operator or an
        // opening bracket, as opposed to after a value.
        var regexAllowed = true
        // The last character that wasn't whitespace or a comment, to tell a property after ".".
        var last: UInt16 = 0
        while i < n {
            let c = u[i]
            let start = i
            if isWhitespace(c) {
                i += 1
                continue
            }
            if c == slash, i + 1 < n, u[i + 1] == slash {
                while i < n, u[i] != newline { i += 1 }
                tokens.append(SyntaxToken(start, i - start, .comment))
                continue
            }
            if c == slash, i + 1 < n, u[i + 1] == star {
                i += 2
                while i < n, !(u[i] == star && i + 1 < n && u[i + 1] == slash) { i += 1 }
                i = min(n, i + 2)
                tokens.append(SyntaxToken(start, i - start, .comment))
                continue
            }
            if c == quote || c == apostrophe || c == backtick {
                i += 1
                while i < n {
                    if u[i] == backslash {
                        i += 2
                    } else if u[i] == c {
                        i += 1
                        break
                    } else if u[i] == newline, c != backtick {
                        break
                    } else {
                        i += 1
                    }
                }
                i = min(i, n)
                tokens.append(SyntaxToken(start, i - start, .string))
                regexAllowed = false
                last = c
                continue
            }
            if isDigit(c) || (c == dot && i + 1 < n && isDigit(u[i + 1]) && last != dot) {
                let hex = c == zero && i + 1 < n && (u[i + 1] | 0x20) == ascii("x")
                i += 1
                while i < n {
                    let d = u[i]
                    if isIdentifierPart(d) || d == dot {
                        i += 1
                    } else if (d == plus || d == minus), !hex, (u[i - 1] | 0x20) == ascii("e") {
                        i += 1
                    } else {
                        break
                    }
                }
                tokens.append(SyntaxToken(start, i - start, .number))
                regexAllowed = false
                last = u[i - 1]
                continue
            }
            if isIdentifierStart(c) {
                while i < n, isIdentifierPart(u[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(u[start..<i]), count: i - start)
                if last == dot {
                    tokens.append(SyntaxToken(start, i - start, .property))
                    regexAllowed = false
                } else if keywords.contains(word) {
                    tokens.append(SyntaxToken(start, i - start, .keyword))
                    regexAllowed = operatorKeywords.contains(word)
                } else {
                    if fields.contains(word) {
                        tokens.append(SyntaxToken(start, i - start, .field))
                    } else if constants.contains(word) {
                        tokens.append(SyntaxToken(start, i - start, .constant))
                    }
                    regexAllowed = false
                }
                last = u[i - 1]
                continue
            }
            if c == slash, regexAllowed, let end = regexLiteralEnd(u, from: i) {
                i = end + 1
                while i < n, isIdentifierPart(u[i]) { i += 1 }
                // A value like a string, with the pattern's own syntax over it.
                tokens.append(SyntaxToken(start, i - start, .string))
                tokens.append(SyntaxToken(start, 1, .regexDelimiter))
                regex(u, (start + 1)..<end, into: &tokens)
                tokens.append(SyntaxToken(end, i - end, .regexDelimiter))
                regexAllowed = false
                last = slash
                continue
            }
            // An operator or punctuation.
            regexAllowed = !(c == closeParen || c == closeBracket || c == closeBrace)
            last = c
            i += 1
        }
        return tokens
    }

    /// The closing slash of a regex literal starting at `start`, or nil if the line ends first.
    private static func regexLiteralEnd(_ u: [UInt16], from start: Int) -> Int? {
        var i = start + 1
        var inClass = false
        while i < u.count {
            switch u[i] {
            case newline: return nil
            case backslash: i += 1
            case openBracket: inClass = true
            case closeBracket: inClass = false
            case slash where !inClass: return i > start + 1 ? i : nil
            default: break
            }
            i += 1
        }
        return nil
    }

    // MARK: Regular expressions

    /// Tokens for the pattern in `u[range]`, in ICU syntax (NSRegularExpression), which covers
    /// JavaScript's too.
    private static func regex(_ u: [UInt16], _ range: Range<Int>, into tokens: inout [SyntaxToken]) {
        var i = range.lowerBound
        let end = range.upperBound
        // Opening parentheses waiting to be closed, as indices into `tokens`.
        var open: [Int] = []
        // Whether a quantifier here has something to repeat.
        var canRepeat = false
        while i < end {
            let c = u[i]
            let start = i
            switch c {
            case backslash:
                i = escapeEnd(u, from: i, end: end)
                if i - start < 2 {
                    tokens.append(SyntaxToken(start, i - start, .error))
                } else {
                    let anchor = "bBAzZG".utf16.contains(u[start + 1])
                    tokens.append(SyntaxToken(start, i - start, anchor ? .regexAnchor : .regexEscape))
                    canRepeat = !anchor
                }
                continue
            case openBracket:
                i = classEnd(u, from: i, end: end, into: &tokens)
                canRepeat = true
                continue
            case openParen:
                i += 1
                if i < end, u[i] == question {
                    i += 1
                    switch i < end ? u[i] : 0 {
                    case hash:
                        // (?#comment)
                        while i < end, u[i] != closeParen { i += 1 }
                        i = min(end, i + 1)
                        tokens.append(SyntaxToken(start, i - start, .comment))
                        continue
                    case colon, equals, bang, greater:
                        // (?:  (?=  (?!  (?>
                        i += 1
                    case less:
                        if i + 1 < end, u[i + 1] == equals || u[i + 1] == bang {
                            // (?<=  (?<!
                            i += 2
                        } else {
                            // (?<name>
                            while i < end, u[i] != greater { i += 1 }
                            i = min(end, i + 1)
                        }
                    default:
                        // Flags: (?i)  (?i-m:
                        while i < end, isLetter(u[i]) || u[i] == minus { i += 1 }
                        if i < end, u[i] == colon { i += 1 }
                    }
                }
                open.append(tokens.count)
                tokens.append(SyntaxToken(start, i - start, .regexGroup))
                canRepeat = false
                continue
            case closeParen:
                if open.popLast() != nil {
                    tokens.append(SyntaxToken(start, 1, .regexGroup))
                    canRepeat = true
                } else {
                    tokens.append(SyntaxToken(start, 1, .error))
                }
            case pipe:
                tokens.append(SyntaxToken(start, 1, .regexAlternation))
                canRepeat = false
            case caret, dollar:
                tokens.append(SyntaxToken(start, 1, .regexAnchor))
                canRepeat = false
            case dot:
                tokens.append(SyntaxToken(start, 1, .regexWildcard))
                canRepeat = true
            case star, plus, question, openBrace:
                var j = i + 1
                if c == openBrace {
                    guard let close = braceQuantifierEnd(u, from: i, end: end) else {
                        canRepeat = true // a literal brace
                        break
                    }
                    j = close + 1
                }
                // Lazy (?) or possessive (+).
                if j < end, u[j] == question || u[j] == plus {
                    j += 1
                }
                tokens.append(SyntaxToken(start, j - start, canRepeat ? .regexQuantifier : .error))
                canRepeat = false
                i = j
                continue
            default:
                canRepeat = true
            }
            i += 1
        }
        for index in open {
            tokens[index].kind = .error
        }
    }

    /// Where the escape starting with the backslash at `start` ends.
    private static func escapeEnd(_ u: [UInt16], from start: Int, end: Int) -> Int {
        var i = start + 1
        guard i < end else { return end }
        let c = u[i]
        i += 1
        switch c {
        case ascii("p"), ascii("P"), ascii("N"), ascii("x"), ascii("u"), ascii("k"):
            if i < end, u[i] == openBrace || (c == ascii("k") && u[i] == less) {
                let close = u[i] == less ? greater : closeBrace
                while i < end, u[i] != close { i += 1 }
                return min(end, i + 1)
            }
            if c == ascii("x") || c == ascii("u") {
                let digits = c == ascii("x") ? 2 : 4
                var count = 0
                while i < end, count < digits, isHexDigit(u[i]) {
                    i += 1
                    count += 1
                }
            }
            return i
        case ascii("c"):
            return min(end, i + 1)
        case ascii("Q"):
            // Quoted literally until \E.
            while i + 1 < end, !(u[i] == backslash && u[i + 1] == ascii("E")) { i += 1 }
            return min(end, i + 2)
        default:
            return i
        }
    }

    /// Adds the character class starting at the bracket at `start`, and returns where it ends.
    private static func classEnd(_ u: [UInt16], from start: Int, end: Int, into tokens: inout [SyntaxToken]) -> Int {
        var i = start + 1
        if i < end, u[i] == caret { i += 1 }
        // A bracket right after the opening one is a literal.
        if i < end, u[i] == closeBracket { i += 1 }
        var escapes: [SyntaxToken] = []
        var depth = 1
        while i < end {
            if u[i] == backslash {
                let escapeStart = i
                i = escapeEnd(u, from: i, end: end)
                escapes.append(SyntaxToken(escapeStart, i - escapeStart, i - escapeStart < 2 ? .error : .regexEscape))
                continue
            }
            if u[i] == openBracket {
                depth += 1 // ICU's nested sets, as in [[a-z]&&[^aeiou]]
            } else if u[i] == closeBracket {
                depth -= 1
                if depth == 0 {
                    i += 1
                    tokens.append(SyntaxToken(start, i - start, .regexClass))
                    tokens += escapes
                    return i
                }
            }
            i += 1
        }
        // Never closed.
        tokens.append(SyntaxToken(start, end - start, .regexClass))
        tokens += escapes
        tokens.append(SyntaxToken(start, 1, .error))
        return end
    }

    /// The closing brace of a counted quantifier (`{2}`, `{2,}`, `{2,5}`) at `start`, or nil when
    /// the brace is a literal.
    private static func braceQuantifierEnd(_ u: [UInt16], from start: Int, end: Int) -> Int? {
        var i = start + 1
        var digits = 0
        while i < end, isDigit(u[i]) {
            i += 1
            digits += 1
        }
        guard digits > 0 else { return nil }
        if i < end, u[i] == comma {
            i += 1
            while i < end, isDigit(u[i]) { i += 1 }
        }
        return i < end && u[i] == closeBrace ? i : nil
    }

    // MARK: Characters

    private static func ascii(_ c: Unicode.Scalar) -> UInt16 {
        UInt16(c.value)
    }

    private static let space = ascii(" "), tab = ascii("\t"), newline = ascii("\n")
    private static let slash = ascii("/"), backslash = ascii("\\"), star = ascii("*")
    private static let quote = ascii("\""), apostrophe = ascii("'"), backtick = ascii("`")
    private static let dot = ascii("."), zero = ascii("0"), plus = ascii("+"), minus = ascii("-")
    private static let openParen = ascii("("), closeParen = ascii(")")
    private static let openBracket = ascii("["), closeBracket = ascii("]")
    private static let openBrace = ascii("{"), closeBrace = ascii("}")
    private static let pipe = ascii("|"), caret = ascii("^"), dollar = ascii("$")
    private static let question = ascii("?"), colon = ascii(":"), comma = ascii(",")
    private static let hash = ascii("#"), less = ascii("<"), greater = ascii(">")
    private static let equals = ascii("="), bang = ascii("!")

    private static func isWhitespace(_ c: UInt16) -> Bool {
        c == space || c == tab || c == newline || c == ascii("\r") || c == 0xA0 || c == 0xFEFF
    }

    private static func isDigit(_ c: UInt16) -> Bool {
        c >= ascii("0") && c <= ascii("9")
    }

    private static func isHexDigit(_ c: UInt16) -> Bool {
        isDigit(c) || ((c | 0x20) >= ascii("a") && (c | 0x20) <= ascii("f"))
    }

    private static func isLetter(_ c: UInt16) -> Bool {
        let lower = c | 0x20
        return lower >= ascii("a") && lower <= ascii("z")
    }

    private static func isIdentifierStart(_ c: UInt16) -> Bool {
        isLetter(c) || c == ascii("_") || c == dollar || (c >= 0x80 && !isWhitespace(c))
    }

    private static func isIdentifierPart(_ c: UInt16) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }
}
