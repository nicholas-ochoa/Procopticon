import CQuickJS
import Foundation
import ProcopticonCore

/// What an expression sees for one field of a row.
public enum ExpressionValue {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null
    case date(Date)
    case strings([String])

    fileprivate func write(to out: OpaquePointer) {
        switch self {
        case .number(let value):
            qx_out_number(out, value)
        case .string(var text):
            text.withUTF8 { qx_out_string(out, Self.chars($0), $0.count) }
        case .bool(let value):
            qx_out_bool(out, value)
        case .null:
            qx_out_null(out)
        case .date(let date):
            qx_out_date(out, date.timeIntervalSince1970)
        case .strings(let list):
            qx_out_array(out)
            for var text in list {
                text.withUTF8 { qx_out_append_string(out, Self.chars($0), $0.count) }
            }
        }
    }

    private static func chars(_ utf8: UnsafeBufferPointer<UInt8>) -> UnsafePointer<CChar>? {
        utf8.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
    }
}

/// A value of each row that expressions use as a variable, such as a process's `cpu`.
public struct ExpressionField<Row> {
    public enum Kind: String {
        case number, string, boolean, date
        case strings = "array of strings"
    }

    public let name: String
    public let kind: Kind
    /// What it is, for the reference.
    public let help: String
    let value: (Row) -> ExpressionValue

    public init(_ name: String, _ kind: Kind, _ help: String, _ value: @escaping (Row) -> ExpressionValue) {
        self.name = name
        self.kind = kind
        self.help = help
        self.value = value
    }
}

/// How long one evaluation may run. An expression that takes longer is stopped and not run again.
let timeoutSeconds = 0.25

/// How long an expression may run in all within `budgetWindow`. One evaluation's limit doesn't
/// bound a pass over a list: 100 ms a row is within it, and is minutes over a thousand rows.
let budgetSeconds = 0.5
let budgetWindow = 1.0

extension ExpressionError {
    public static let timeout = ExpressionError(
        message: "The expression took more than \(Int(timeoutSeconds * 1000)) ms and was stopped", timedOut: true)
    public static let overBudget = ExpressionError(
        message: "The expression took more than \(Int(budgetSeconds * 1000)) ms over the list and was stopped", timedOut: true)
}

/// Reads a field for the C bridge, which knows rows only as pointers.
private final class FieldReader {
    let read: (UnsafeMutableRawPointer, Int32, OpaquePointer) -> Void

    init(_ read: @escaping (UnsafeMutableRawPointer, Int32, OpaquePointer) -> Void) {
        self.read = read
    }
}

private let readField: qx_field_getter = { context, row, field, out in
    Unmanaged<FieldReader>.fromOpaque(context!).takeUnretainedValue().read(row, field, out)
}

/// Evaluates JavaScript expressions over rows, with QuickJS. The row's fields are the
/// expression's variables, read only when it uses them: `cpu > 50 && /safari/i.test(name)`.
///
/// Each engine is a separate JavaScript context with no access to files, the network or timers,
/// limited to 32 MB of memory; an evaluation that runs too long is stopped (see `ExpressionError`).
/// An engine isn't thread-safe: use it from one thread or serial queue at a time. Compiled
/// expressions may be released anywhere.
public final class ExpressionEngine<Row: AnyObject> {
    public let fields: [ExpressionField<Row>]
    private let reader: FieldReader
    private let engine: OpaquePointer?
    /// Why the engine couldn't start (it shouldn't happen).
    private let startupError: String?
    /// Recently compiled expressions by source, most recent last.
    private var cache: [String: CompiledExpression<Row>] = [:]
    private var cacheOrder: [String] = []
    private static var cacheSize: Int { 32 }
    private let releaseLock = NSLock()
    private var released: [Int32] = []

    public init(fields: [ExpressionField<Row>], prelude: String? = nil) {
        self.fields = fields
        let reader = FieldReader { row, field, out in
            let item = Unmanaged<Row>.fromOpaque(row).takeUnretainedValue()
            fields[Int(field)].value(item).write(to: out)
        }
        self.reader = reader
        let names = fields.map { strdup($0.name) }
        defer { names.forEach { free($0) } }
        var error: UnsafeMutablePointer<CChar>?
        let pointers = names.map { UnsafePointer($0!) }
        engine = pointers.withUnsafeBufferPointer {
            qx_engine_new($0.baseAddress!, Int32(fields.count), readField, Unmanaged.passUnretained(reader).toOpaque(),
                          prelude, 32 << 20, &error)
        }
        startupError = engine == nil ? Self.take(error) : nil
    }

    deinit {
        if let engine {
            qx_engine_free(engine)
        }
    }

    /// Compiles `source`, or returns the recent compilation of the same text.
    public func compile(_ source: String) -> CompiledExpression<Row> {
        if let cached = cache[source] {
            cacheOrder.removeAll { $0 == source }
            cacheOrder.append(source)
            return cached
        }
        let compiled: CompiledExpression<Row>
        if let engine {
            freeReleased()
            var error: UnsafeMutablePointer<CChar>?
            let id = qx_compile(engine, source, timeoutSeconds, &error)
            compiled = CompiledExpression(source: source, id: id, error: id < 0 ? Self.take(error) : nil, engine: self)
        } else {
            compiled = CompiledExpression(source: source, id: -1, error: startupError, engine: self)
        }
        cache[source] = compiled
        cacheOrder.append(source)
        if cacheOrder.count > Self.cacheSize {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return compiled
    }

    fileprivate func evaluate(_ id: Int32, _ row: Row) -> Result<Bool, ExpressionError> {
        guard let engine else {
            return .failure(ExpressionError(message: startupError ?? ""))
        }
        freeReleased()
        var error: UnsafeMutablePointer<CChar>?
        let result = withExtendedLifetime(row) {
            qx_evaluate(engine, id, Unmanaged.passUnretained(row).toOpaque(), timeoutSeconds, &error)
        }
        if result == QX_TRUE {
            return .success(true)
        } else if result == QX_FALSE {
            return .success(false)
        } else if result == QX_TIMEOUT {
            return .failure(.timeout)
        }
        return .failure(ExpressionError(message: Self.take(error)))
    }

    /// Frees a compiled expression the next time the engine is used, on its own thread.
    fileprivate func release(_ id: Int32) {
        releaseLock.lock()
        released.append(id)
        releaseLock.unlock()
    }

    private func freeReleased() {
        releaseLock.lock()
        let ids = released
        released.removeAll()
        releaseLock.unlock()
        for id in ids {
            qx_release(engine!, id)
        }
    }

    private static func take(_ error: UnsafeMutablePointer<CChar>?) -> String {
        guard let error else { return "Unknown error" }
        defer { free(error) }
        return String(cString: error)
    }
}

/// An expression compiled by an `ExpressionEngine`, or the error that kept it from compiling.
/// Use it on the engine's thread.
public final class CompiledExpression<Row: AnyObject> {
    public let source: String
    /// Why it didn't compile, e.g. "SyntaxError: unexpected token in expression: ')'".
    public let error: String?
    private let id: Int32
    private weak var engine: ExpressionEngine<Row>?
    /// Set once an evaluation ran out of time; the expression isn't run again.
    public private(set) var timedOut = false
    /// Set once the evaluations together ran out of time (see `budgetSeconds`).
    private var overBudget = false
    private var windowStart: UInt64 = 0
    private var windowSpent: UInt64 = 0

    fileprivate init(source: String, id: Int32, error: String?, engine: ExpressionEngine<Row>) {
        self.source = source
        self.id = id
        self.error = error
        self.engine = engine
    }

    deinit {
        if id >= 0 {
            engine?.release(id)
        }
    }

    /// Whether the expression is truthy for `row`, or why it couldn't tell.
    public func evaluate(_ row: Row) -> Result<Bool, ExpressionError> {
        if let error {
            return .failure(ExpressionError(message: error))
        }
        if timedOut {
            return .failure(overBudget ? .overBudget : .timeout)
        }
        guard let engine else {
            return .failure(ExpressionError(message: "The expression's engine is gone"))
        }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let result = engine.evaluate(id, row)
        if case .failure(let e) = result, e.timedOut {
            timedOut = true
            return result
        }
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if start &- windowStart > UInt64(budgetWindow * 1e9) {
            windowStart = start
            windowSpent = 0
        }
        windowSpent &+= end &- start
        if windowSpent > UInt64(budgetSeconds * 1e9) {
            timedOut = true
            overBudget = true
            return .failure(.overBudget)
        }
        return result
    }

    /// True when the expression is truthy for `row`; false when it isn't, or fails.
    public func matches(_ row: Row) -> Bool {
        if case .success(true) = evaluate(row) {
            return true
        }
        return false
    }
}
