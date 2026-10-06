import Foundation

/// Compiled search text used by every filter field.
///
/// * Plain text matches as a case-insensitive substring.
/// * `/pattern/` is always treated as a regular expression (case-insensitive); add the `c` flag
///   (`/pattern/c`) to make it case-sensitive.
/// * When `regex` is true, the whole text is a case-insensitive regular expression.
public struct SearchMatcher: @unchecked Sendable {
    private enum Mode {
        case empty
        case substring(String)
        case regex(NSRegularExpression)
        case invalid
    }

    private let mode: Mode
    /// Description of why the regular expression failed to compile, if it did.
    public let error: String?

    public init(_ raw: String, regex regexMode: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            mode = .empty
            error = nil
            return
        }
        var pattern: String?
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if let (body, flags) = Self.slashDelimited(text) {
            pattern = body
            if flags.contains("c") {
                options.remove(.caseInsensitive)
            }
        } else if regexMode {
            pattern = text
        }
        guard let pattern else {
            mode = .substring(text)
            error = nil
            return
        }
        do {
            mode = .regex(try NSRegularExpression(pattern: pattern, options: options))
            error = nil
        } catch {
            mode = .invalid
            self.error = Self.describe(error, pattern: pattern)
        }
    }

    /// `/body/flags` where flags are drawn from "ic". Returns nil for anything else (e.g. a path).
    static func slashDelimited(_ text: String) -> (String, String)? {
        guard text.count >= 3, text.hasPrefix("/"), let last = text.lastIndex(of: "/"), last > text.startIndex else {
            return nil
        }
        let flags = String(text[text.index(after: last)...])
        guard flags.allSatisfy({ "ic".contains($0) }) else { return nil }
        let body = String(text[text.index(after: text.startIndex)..<last])
        return body.isEmpty ? nil : (body, flags)
    }

    private static func describe(_ error: Error, pattern: String) -> String {
        let ns = error as NSError
        if let reason = ns.userInfo["NSInvalidValue"] as? String {
            return "Invalid regular expression: \(reason)"
        }
        return "Invalid regular expression “\(pattern)”"
    }

    public var isEmpty: Bool {
        if case .empty = mode { return true }
        return false
    }

    public var isRegex: Bool {
        switch mode {
        case .regex, .invalid: return true
        default: return false
        }
    }

    public var isValid: Bool { error == nil }

    /// True if `value` contains a match. An empty matcher matches everything; an invalid one nothing.
    public func matches(_ value: String?) -> Bool {
        switch mode {
        case .empty:
            return true
        case .invalid:
            return false
        case .substring(let needle):
            guard let value else { return false }
            return value.localizedCaseInsensitiveContains(needle)
        case .regex(let re):
            guard let value else { return false }
            return re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
    }

    /// For identifiers such as PIDs and ports: plain text must match exactly, a regex searches.
    public func matchesIdentifier(_ value: String) -> Bool {
        switch mode {
        case .substring(let needle): return value == needle
        default: return matches(value)
        }
    }

    /// True if any of the values match.
    public func matchesAny(_ values: String?...) -> Bool {
        values.contains { matches($0) }
    }
}
