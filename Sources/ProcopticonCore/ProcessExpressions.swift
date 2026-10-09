import Foundation

/// Compiles JavaScript expressions over processes (see `ProcessExpressions`). The engine itself,
/// QuickJS, is in the ProcopticonExpressions module: the app links it, the root helper (which links
/// this module too) doesn't. Use an engine from one thread or serial queue at a time.
public protocol ProcessExpressionCompiler: AnyObject {
    func compileProcessExpression(_ source: String) -> any CompiledProcessExpression
}

/// An expression compiled by a `ProcessExpressionCompiler`, or the error that kept it from
/// compiling. Use it on its compiler's thread.
public protocol CompiledProcessExpression: AnyObject {
    /// Why it didn't compile.
    var error: String? { get }
    /// Whether the expression is truthy for `item`, or why it couldn't tell.
    func evaluate(_ item: ProcessItem) -> Result<Bool, ExpressionError>
}

extension CompiledProcessExpression {
    /// True when the expression is truthy for `item`; false when it isn't, or fails.
    public func matches(_ item: ProcessItem) -> Bool {
        if case .success(true) = evaluate(item) {
            return true
        }
        return false
    }
}

/// Why an expression gave no result.
public struct ExpressionError: Error, Equatable {
    public var message: String
    /// It ran past its time limit and was stopped.
    public var timedOut = false

    public init(message: String, timedOut: Bool = false) {
        self.message = message
        self.timedOut = timedOut
    }
}

/// Counts the errors from evaluating an expression over many rows, to report the first.
public struct ExpressionErrors {
    public private(set) var first: ExpressionError?
    public private(set) var count = 0

    public init() {}

    public mutating func record(_ error: ExpressionError) {
        if first == nil {
            first = error
        }
        count += 1
    }

    /// The first error, and how many rows failed: "TypeError: … (in 3 processes)".
    public func summary(rows noun: String) -> String? {
        guard let first else { return nil }
        if first.timedOut || count < 2 {
            return first.message
        }
        return "\(first.message) (in \(count) \(noun))"
    }
}

/// Stands in for an expression when there's no engine to compile it.
private final class UnavailableExpression: CompiledProcessExpression {
    let error: String? = "Expressions aren't available here"

    func evaluate(_ item: ProcessItem) -> Result<Bool, ExpressionError> {
        .failure(ExpressionError(message: error!))
    }
}

/// How filter text matches: as plain text, a regular expression, or (for processes) a JavaScript
/// expression over the process's values.
public enum SearchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, regex, javascript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: return "Text"
        case .regex: return "Regex"
        case .javascript: return "JavaScript"
        }
    }

    /// Filter text in this mode, for a summary: “text”, /regex/ or the expression as it is.
    public func describe(_ text: String) -> String {
        switch self {
        case .text: return "“\(text)”"
        case .regex: return "/\(text)/"
        case .javascript: return text
        }
    }
}

/// JavaScript expressions over a process's values, for the process search, saved filters, custom
/// highlight rules and alerts. Their fields are in the ProcopticonExpressions module.
public enum ProcessExpressions {
    /// The expression in text written as "=expression", which is how an expression was entered
    /// before filters had a mode; nil for other text. For converting saved settings.
    public static func legacyExpression(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("=") else { return nil }
        return t.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What filter text selects among processes: plain text or a regular expression (see
/// `SearchMatcher`) against the name, PID, path, command line, user and bundle ID, or a JavaScript
/// expression over the process's fields (see `ProcessExpressions`).
public struct ProcessMatcher {
    private enum Kind {
        case text(SearchMatcher)
        case expression(any CompiledProcessExpression)
    }

    private let kind: Kind

    /// `engine` compiles an expression; use the matcher on the engine's thread.
    public init(_ text: String, mode: SearchMode, engine: (any ProcessExpressionCompiler)?) {
        switch mode {
        case .text, .regex:
            kind = .text(SearchMatcher(text, regex: mode == .regex))
        case .javascript:
            let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Like empty search text, an empty expression matches everything.
            kind = source.isEmpty ? .text(SearchMatcher(""))
                : .expression(engine?.compileProcessExpression(source) ?? UnavailableExpression())
        }
    }

    /// Matches every process.
    public var isEmpty: Bool {
        if case .text(let m) = kind { return m.isEmpty }
        return false
    }

    public var isExpression: Bool {
        if case .expression = kind { return true }
        return false
    }

    /// Why the text can't be used: an invalid regular expression, or an expression that doesn't
    /// compile.
    public var error: String? {
        switch kind {
        case .text(let m): return m.error
        case .expression(let e): return e.error
        }
    }

    public var isValid: Bool { error == nil }

    /// Whether `item` matches, or why an expression couldn't tell.
    public func evaluate(_ item: ProcessItem) -> Result<Bool, ExpressionError> {
        switch kind {
        case .text(let m): return .success(m.isEmpty || item.matches(m))
        case .expression(let e): return e.evaluate(item)
        }
    }

    /// True when `item` matches; false when it doesn't, or an expression fails for it.
    public func matches(_ item: ProcessItem) -> Bool {
        if case .success(true) = evaluate(item) {
            return true
        }
        return false
    }
}

/// A custom highlight rule as the store evaluates it: processes matching `text` (in `mode`) get
/// `id` as their `ProcessItem.customHighlight` (the first such rule's).
public struct HighlightFilter: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var mode: SearchMode

    public init(id: UUID, text: String, mode: SearchMode) {
        self.id = id
        self.text = text
        self.mode = mode
    }
}
