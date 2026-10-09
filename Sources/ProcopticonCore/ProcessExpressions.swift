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

/// JavaScript expressions over a process's values, for the search field ("=cpu > 50"), custom
/// highlight rules and alert conditions.
public enum ProcessExpressions {
    /// Search text starting with this is an expression.
    public static let prefix = "="

    /// The expression in search text written as "=expression", or nil for other text.
    public static func expression(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(prefix) else { return nil }
        return t.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An expression typed where only expressions go (a highlight rule, an alert condition), which
    /// may also be written with the "=" of the search field.
    public static func source(_ text: String) -> String {
        expression(in: text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What search text selects in the process list: plain text or a regular expression (see
/// `SearchMatcher`) against the name, PID, path, command line, user and bundle ID, or, written as
/// "=expression", a JavaScript expression over the process's fields (see `ProcessExpressions`).
public struct ProcessMatcher {
    private enum Mode {
        case text(SearchMatcher)
        case expression(any CompiledProcessExpression)
    }

    private let mode: Mode

    /// `engine` compiles an expression; use the matcher on the engine's thread.
    public init(_ text: String, regex: Bool = false, engine: (any ProcessExpressionCompiler)?) {
        if let source = ProcessExpressions.expression(in: text) {
            // "=" alone, as you start typing an expression, still shows everything.
            mode = source.isEmpty ? .text(SearchMatcher(""))
                : .expression(engine?.compileProcessExpression(source) ?? UnavailableExpression())
        } else {
            mode = .text(SearchMatcher(text, regex: regex))
        }
    }

    /// Matches every process.
    public var isEmpty: Bool {
        if case .text(let m) = mode { return m.isEmpty }
        return false
    }

    public var isExpression: Bool {
        if case .expression = mode { return true }
        return false
    }

    /// Why the text can't be used: an invalid regular expression, or an expression that doesn't
    /// compile.
    public var error: String? {
        switch mode {
        case .text(let m): return m.error
        case .expression(let e): return e.error
        }
    }

    public var isValid: Bool { error == nil }

    /// Whether `item` matches, or why an expression couldn't tell.
    public func evaluate(_ item: ProcessItem) -> Result<Bool, ExpressionError> {
        switch mode {
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

/// A custom highlight rule as the store evaluates it: processes meeting `expression` get `id` as
/// their `ProcessItem.customHighlight` (the first such rule's).
public struct HighlightExpression: Equatable, Sendable {
    public var id: UUID
    public var expression: String

    public init(id: UUID, expression: String) {
        self.id = id
        self.expression = expression
    }
}
