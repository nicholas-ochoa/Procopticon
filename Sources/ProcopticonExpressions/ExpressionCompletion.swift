import Foundation
import ProcopticonCore

/// What can complete the word at the caret in a process expression: the process's values,
/// constants and a few keywords, or after a dot, the properties and methods of what's before it
/// when its type is known (`name.` gets string methods, `args.` array methods).
public struct ExpressionCompletion: Equatable {
    public struct Item: Equatable, Identifiable {
        public enum Kind: Equatable {
            case field, constant, keyword, global, property, method
        }

        public var name: String
        public var kind: Kind
        /// Its type or what it is, such as "number" or "method".
        public var detail: String
        public var help: String
        /// A method's parameters, as shown: "text" for includes(text).
        public var parameters: String?

        public var id: String { name }

        /// How it's listed: a method with its parameters.
        public var label: String {
            parameters.map { "\(name)(\($0))" } ?? name
        }

        /// What accepting it inserts, and where the caret goes in that: between a method's
        /// parentheses when it takes arguments, after them when it doesn't.
        public var insertion: (text: String, caret: Int) {
            guard let parameters else { return (name, name.utf16.count) }
            return ("\(name)()", name.utf16.count + (parameters.isEmpty ? 2 : 1))
        }

        init(_ name: String, _ kind: Kind, _ detail: String, _ help: String, parameters: String? = nil) {
            self.name = name
            self.kind = kind
            self.detail = detail
            self.help = help
            self.parameters = parameters
        }
    }

    /// The word the completion replaces (all of it, if the caret is inside), in UTF-16 offsets.
    public var range: NSRange
    /// The part of the word before the caret, which the items match.
    public var prefix: String
    /// Matches by prefix first, then those containing the prefix elsewhere.
    public var items: [Item]

    /// Completions at `caret` (a UTF-16 offset) in `text`; nil inside a string, comment or regex,
    /// in a number, after a dot following something of unknown type, or when nothing matches.
    /// Unless `explicit`, an empty word outside member access gets nothing.
    public static func at(_ caret: Int, in text: String, explicit: Bool = false) -> ExpressionCompletion? {
        let u = Array(text.utf16)
        guard caret >= 0, caret <= u.count, !insideLiteral(caret, in: text) else { return nil }
        var start = caret
        while start > 0, isIdentifierPart(u[start - 1]) { start -= 1 }
        var end = caret
        while end < u.count, isIdentifierPart(u[end]) { end += 1 }
        let prefix = String(utf16CodeUnits: Array(u[start..<caret]), count: caret - start)
        if let first = prefix.utf16.first, isDigit(first) {
            return nil
        }
        let candidates: [Item]
        if start > 0, u[start - 1] == dot {
            guard start < 2 || u[start - 2] != dot, let members = members(after: start - 1, in: u, text: text) else { return nil }
            candidates = members
        } else {
            guard !prefix.isEmpty || explicit else { return nil }
            candidates = globals
        }
        let items = match(candidates, prefix)
        // Nothing to complete when the word is already the only match.
        guard !items.isEmpty, !(items.count == 1 && items[0].name == prefix) else { return nil }
        return ExpressionCompletion(range: NSRange(location: start, length: end - start), prefix: prefix, items: items)
    }

    // MARK: Matching

    private static func match(_ candidates: [Item], _ prefix: String) -> [Item] {
        guard !prefix.isEmpty else { return candidates }
        let lower = prefix.lowercased()
        let starting = candidates.filter { $0.name.lowercased().hasPrefix(lower) }
        let containing = candidates.filter { !$0.name.lowercased().hasPrefix(lower) && $0.name.lowercased().contains(lower) }
        // The exact case first among those starting with the prefix ("cpu" before "cpuUser").
        let exact = starting.filter { $0.name.hasPrefix(prefix) }
        return exact + starting.filter { !$0.name.hasPrefix(prefix) } + containing
    }

    private static func insideLiteral(_ caret: Int, in text: String) -> Bool {
        let ns = text as NSString
        for token in SyntaxHighlighting.tokens(text, mode: .javascript) where token.kind == .string || token.kind == .comment {
            let r = token.range
            if r.location < caret, caret < NSMaxRange(r) {
                return true
            }
            // At the end of an unfinished string or comment, the caret is still in it.
            if caret == NSMaxRange(r) {
                let s = ns.substring(with: r)
                let unfinished = token.kind == .string
                    ? s.count < 2 || s.last != s.first
                    : s.hasPrefix("//") || !s.hasSuffix("*/")
                if unfinished { return true }
            }
        }
        return false
    }

    // MARK: Candidates

    /// The values, constants, keywords and objects an expression starts from.
    static let globals: [Item] = {
        var items = ProcessExpressions.fields.map { field in
            Item(field.name, .field, field.kind.rawValue, field.help)
        }
        items += [
            Item("KB", .constant, "constant", "1024 bytes"),
            Item("MB", .constant, "constant", "1024 KB"),
            Item("GB", .constant, "constant", "1024 MB"),
            Item("TB", .constant, "constant", "1024 GB"),
            Item("true", .keyword, "keyword", "Yes"),
            Item("false", .keyword, "keyword", "No"),
            Item("null", .keyword, "keyword", "No value: what unknown numbers and yes/no values are"),
            Item("typeof", .keyword, "keyword", "The type of a value, as text: typeof ports == \"number\""),
            Item("Math", .global, "object", "Math functions: Math.max(a, b), Math.round(x)"),
            Item("Date", .global, "object", "Dates and times: Date.now()"),
        ]
        return items
    }()

    private enum ValueType {
        case string, strings, number, date, regex, math, dateObject
    }

    private static func members(of type: ValueType) -> [Item] {
        switch type {
        case .string:
            return [
                Item("length", .property, "number", "The number of characters"),
                Item("includes", .method, "boolean", "Whether the text contains this", parameters: "text"),
                Item("startsWith", .method, "boolean", "Whether the text starts with this", parameters: "text"),
                Item("endsWith", .method, "boolean", "Whether the text ends with this", parameters: "text"),
                Item("toLowerCase", .method, "string", "The text in lowercase, to compare ignoring case", parameters: ""),
                Item("toUpperCase", .method, "string", "The text in uppercase", parameters: ""),
                Item("indexOf", .method, "number", "Where this first appears in the text, or -1", parameters: "text"),
                Item("match", .method, "array", "The matches of a regular expression, or null", parameters: "regex"),
                Item("split", .method, "array of strings", "The parts between each separator", parameters: "separator"),
                Item("trim", .method, "string", "The text without spaces at either end", parameters: ""),
                Item("slice", .method, "string", "Part of the text, from start up to end", parameters: "start, end"),
                Item("replace", .method, "string", "The text with a part replaced", parameters: "text, replacement"),
            ]
        case .strings:
            return [
                Item("length", .property, "number", "The number of elements"),
                Item("includes", .method, "boolean", "Whether one element is exactly this", parameters: "text"),
                Item("some", .method, "boolean", "Whether the function is true for any element: args.some(a => a.startsWith(\"--\"))",
                     parameters: "element => …"),
                Item("every", .method, "boolean", "Whether the function is true for every element", parameters: "element => …"),
                Item("find", .method, "string", "The first element the function is true for", parameters: "element => …"),
                Item("filter", .method, "array of strings", "The elements the function is true for", parameters: "element => …"),
                Item("indexOf", .method, "number", "Where the element first appears, or -1", parameters: "text"),
                Item("join", .method, "string", "The elements as one text, with a separator between them", parameters: "separator"),
                Item("at", .method, "string", "The element at an index; negative counts from the end", parameters: "index"),
            ]
        case .number:
            return [
                Item("toFixed", .method, "string", "The number with this many decimals", parameters: "digits"),
                Item("toString", .method, "string", "The number as text", parameters: ""),
            ]
        case .date:
            return [
                Item("getTime", .method, "number", "Milliseconds since 1970", parameters: ""),
                Item("getHours", .method, "number", "The hour, 0–23", parameters: ""),
                Item("getDay", .method, "number", "The day of the week, 0 (Sunday) to 6", parameters: ""),
                Item("getDate", .method, "number", "The day of the month", parameters: ""),
                Item("getFullYear", .method, "number", "The year", parameters: ""),
                Item("toISOString", .method, "string", "The date as ISO 8601 text", parameters: ""),
            ]
        case .regex:
            return [
                Item("test", .method, "boolean", "Whether the text contains a match", parameters: "text"),
                Item("exec", .method, "array", "The first match and its groups, or null", parameters: "text"),
                Item("source", .property, "string", "The pattern"),
                Item("flags", .property, "string", "The flags, such as i"),
            ]
        case .math:
            return [
                Item("max", .method, "number", "The largest of the numbers", parameters: "a, b"),
                Item("min", .method, "number", "The smallest of the numbers", parameters: "a, b"),
                Item("abs", .method, "number", "The number without its sign", parameters: "x"),
                Item("round", .method, "number", "The nearest whole number", parameters: "x"),
                Item("floor", .method, "number", "The whole number at or below", parameters: "x"),
                Item("ceil", .method, "number", "The whole number at or above", parameters: "x"),
                Item("pow", .method, "number", "x to the power y", parameters: "x, y"),
                Item("sqrt", .method, "number", "The square root", parameters: "x"),
            ]
        case .dateObject:
            return [Item("now", .method, "number", "Milliseconds since 1970, now", parameters: "")]
        }
    }

    /// What methods return, to complete after a call: `name.toLowerCase().` is a string.
    private static let returnTypes: [String: ValueType] = [
        "toLowerCase": .string, "toUpperCase": .string, "trim": .string, "slice": .string, "replace": .string,
        "toFixed": .string, "toString": .string, "toISOString": .string, "join": .string, "find": .string, "at": .string,
        "split": .strings, "filter": .strings,
        "indexOf": .number, "getTime": .number, "getHours": .number, "getDay": .number, "getDate": .number,
        "getFullYear": .number, "max": .number, "min": .number, "abs": .number, "round": .number, "floor": .number,
        "ceil": .number, "pow": .number, "sqrt": .number, "now": .number,
    ]

    /// The members of what comes before the dot at `dot`, if its type can be told.
    private static func members(after dot: Int, in u: [UInt16], text: String) -> [Item]? {
        type(endingAt: dot, in: u, text: text).map(members(of:))
    }

    private static func type(endingAt end: Int, in u: [UInt16], text: String) -> ValueType? {
        guard end > 0 else { return nil }
        if endsRegexLiteral(end, in: text) {
            return .regex
        }
        let last = u[end - 1]
        if isIdentifierPart(last) {
            var start = end - 1
            while start > 0, isIdentifierPart(u[start - 1]) { start -= 1 }
            let word = String(utf16CodeUnits: Array(u[start..<end]), count: end - start)
            if word == "Math" { return .math }
            if word == "Date" { return .dateObject }
            guard let field = ProcessExpressions.fields.first(where: { $0.name == word }) else { return nil }
            switch field.kind {
            case .string: return .string
            case .strings: return .strings
            case .number: return .number
            case .date: return .date
            case .boolean: return nil
            }
        }
        switch last {
        case quote, apostrophe, backtick:
            return .string
        case closeParen:
            // A call: what the method returns.
            guard let open = matching(openParen, closeParen, before: end - 1, in: u) else { return nil }
            var nameEnd = open
            while nameEnd > 0, u[nameEnd - 1] == space { nameEnd -= 1 }
            var start = nameEnd
            while start > 0, isIdentifierPart(u[start - 1]) { start -= 1 }
            let name = String(utf16CodeUnits: Array(u[start..<nameEnd]), count: nameEnd - start)
            return start > 0 && u[start - 1] == dot ? returnTypes[name] : nil
        case closeBracket:
            // An element of an array of strings: args[0].
            guard let open = matching(openBracket, closeBracket, before: end - 1, in: u),
                  type(endingAt: open, in: u, text: text) == .strings else { return nil }
            return .string
        default:
            return nil
        }
    }

    /// Whether a regex literal (with any flags) ends at `end`. (A literal's opening slash also
    /// ends there when the caret is in the literal, but then nothing completes.)
    private static func endsRegexLiteral(_ end: Int, in text: String) -> Bool {
        SyntaxHighlighting.tokens(text, mode: .javascript).contains { $0.kind == .regexDelimiter && NSMaxRange($0.range) == end }
    }

    /// The opening bracket matching the closing one at `close`.
    private static func matching(_ open: UInt16, _ close: UInt16, before closeIndex: Int, in u: [UInt16]) -> Int? {
        var depth = 0
        var i = closeIndex
        while i >= 0 {
            if u[i] == close {
                depth += 1
            } else if u[i] == open {
                depth -= 1
                if depth == 0 { return i }
            }
            i -= 1
        }
        return nil
    }

    // MARK: Characters

    private static let dot = UInt16(UInt8(ascii: ".")), space = UInt16(UInt8(ascii: " "))
    private static let quote = UInt16(UInt8(ascii: "\"")), apostrophe = UInt16(UInt8(ascii: "'")), backtick = UInt16(UInt8(ascii: "`"))
    private static let openParen = UInt16(UInt8(ascii: "(")), closeParen = UInt16(UInt8(ascii: ")"))
    private static let openBracket = UInt16(UInt8(ascii: "[")), closeBracket = UInt16(UInt8(ascii: "]"))

    private static func isDigit(_ c: UInt16) -> Bool {
        c >= 48 && c <= 57
    }

    private static func isIdentifierPart(_ c: UInt16) -> Bool {
        let lower = c | 0x20
        return (lower >= 97 && lower <= 122) || isDigit(c) || c == 95 || c == 36 || c >= 0x80
    }
}
