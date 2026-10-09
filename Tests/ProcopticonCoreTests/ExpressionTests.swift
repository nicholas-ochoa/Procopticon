import XCTest
@testable import ProcopticonCore
import ProcopticonExpressions

final class ExpressionTests: XCTestCase {
    private func item(_ pid: Int32, _ comm: String, uid: UInt32 = 501, cpu: Double = 0, arguments: [String]? = nil,
                      path: String? = nil) -> ProcessItem {
        var r = ProcessRecord(pid: pid, ppid: 1, pgid: pid, uid: uid, ruid: uid, rgid: 20, svuid: uid, status: 2,
                              flags: 0, nice: 0, tty: -1, startMicros: Int64(pid), comm: comm)
        r.arguments = arguments
        r.path = path
        let s = ProcessState(record: r, time: 0, initial: true)
        s.cpu = cpu
        return ProcessItem(s)
    }

    private func value(_ engine: ProcessExpressionEngine, _ source: String, _ item: ProcessItem) -> Result<Bool, ExpressionError> {
        engine.compile(source).evaluate(item)
    }

    func testFieldsAreVariables() {
        let engine = ProcessExpressionEngine()
        let safari = item(42, "Safari", cpu: 75, arguments: ["/Applications/Safari.app/Contents/MacOS/Safari", "--headless"],
                          path: "/Applications/Safari.app/Contents/MacOS/Safari")
        XCTAssertEqual(value(engine, "cpu > 50 && pid === 42", safari), .success(true))
        XCTAssertEqual(value(engine, "cpu > 80", safari), .success(false))
        XCTAssertEqual(value(engine, "/safari/i.test(name) && executable == 'Safari'", safari), .success(true))
        XCTAssertEqual(value(engine, "args.includes('--headless') && args.length == 2", safari), .success(true))
        XCTAssertEqual(value(engine, "path.startsWith('/Applications/')", safari), .success(true))
        XCTAssertEqual(value(engine, "commandLine.endsWith('--headless')", safari), .success(true))
        XCTAssertEqual(value(engine, "uid == 501 && !zombie && !exited", safari), .success(true))
        XCTAssertEqual(value(engine, "startTime instanceof Date && age > 0", safari), .success(true))
        XCTAssertEqual(value(engine, "title === '' && tty === ''", safari), .success(true), "missing text is empty, not null")
        XCTAssertEqual(value(engine, "memory === null && !(memory > 1 * GB)", safari), .success(true), "unknown numbers are null")
        XCTAssertEqual(value(engine, "GB == 1024 * MB && MB == 1024 * KB && TB == 1024 * GB", safari), .success(true))
    }

    func testEveryFieldReads() {
        let engine = ProcessExpressionEngine()
        let p = item(7, "zsh")
        for field in ProcessExpressions.fields {
            XCTAssertEqual(value(engine, "typeof \(field.name) !== 'undefined'", p), .success(true), field.name)
        }
        XCTAssertEqual(Set(ProcessExpressions.fields.map(\.name)).count, ProcessExpressions.fields.count, "unique names")
    }

    func testKeptRowsAreBlankOutsideEvaluations() {
        let engine = ProcessExpressionEngine()
        let a = item(1, "first")
        let b = item(2, "second")
        // An expression can keep the object whose fields it reads...
        XCTAssertEqual(value(engine, "(globalThis.kept = row, name == 'first')", a), .success(true))
        // ...which then reads whichever process is being evaluated,
        XCTAssertEqual(value(engine, "kept.name === 'second'", b), .success(true))
        // and nothing at all between evaluations (here, in code smuggled into a compilation).
        let smuggled = engine.compile("0) }); globalThis.leak = String(kept.name); (function (row) { return (0")
        XCTAssertNil(smuggled.error)
        XCTAssertEqual(value(engine, "leak === 'undefined'", a), .success(true))
    }

    func testSyntaxAndRuntimeErrors() {
        let engine = ProcessExpressionEngine()
        let p = item(3, "launchd")
        // Errors point into the expression, not the code wrapped around it.
        XCTAssertEqual(engine.compile("cpu >").error, "SyntaxError: incomplete expression")
        XCTAssertEqual(engine.compile("(cpu > 5").error, "SyntaxError: incomplete expression")
        XCTAssertEqual(engine.compile("cpu > 5)").error, "SyntaxError: unexpected ')' (at column 8)")
        XCTAssertEqual(engine.compile("cpu > 5 &&\nname == 'a')").error, "SyntaxError: unexpected ')' (line 2, column 12)")
        XCTAssertEqual(engine.compile("foo bar").error, "SyntaxError: Unexpected identifier 'bar' (at column 5)")
        XCTAssertNil(engine.compile("name == ')'").error)
        guard case .failure(let error) = value(engine, "cpuu > 5", p) else {
            return XCTFail("expected a ReferenceError")
        }
        XCTAssertTrue(error.message.contains("ReferenceError"), error.message)
        XCTAssertFalse(error.timedOut)
        // A trailing line comment doesn't swallow the wrapper.
        XCTAssertEqual(value(engine, "pid == 3 // launchd", p), .success(true))
        XCTAssertFalse(engine.compile("pid == 3 // launchd").matches(item(4, "other")))
    }

    func testRunawayExpressionsAreStoppedAndDisabled() {
        let engine = ProcessExpressionEngine()
        let p = item(5, "spin")
        let spin = engine.compile("(() => { while (true) {} })()")
        XCTAssertNil(spin.error)
        let start = Date()
        XCTAssertEqual(spin.evaluate(p), .failure(.timeout))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(spin.timedOut)
        XCTAssertEqual(spin.evaluate(p), .failure(.timeout), "not run again")
        // The engine still works afterwards.
        XCTAssertEqual(value(engine, "pid == 5", p), .success(true))
    }

    func testMemoryAndStackAreLimited() {
        let engine = ProcessExpressionEngine()
        let p = item(6, "hog")
        guard case .failure = value(engine, "'x'.repeat(2 ** 28).length > 0", p) else {
            return XCTFail("expected running out of memory")
        }
        guard case .failure = value(engine, "(function f(n) { return f(n + 1) })(0)", p) else {
            return XCTFail("expected a stack overflow")
        }
        XCTAssertEqual(value(engine, "pid == 6", p), .success(true))
    }

    func testEnginesWorkFromOtherThreads() {
        let engine = ProcessExpressionEngine()
        let p = item(8, "worker")
        let expression = engine.compile("(function f(n) { return n ? f(n - 1) : pid == 8 })(20)")
        var results: [Result<Bool, ExpressionError>] = []
        let lock = NSLock()
        // One at a time, on dispatch worker threads (512 KB stacks), as from a serial queue.
        for _ in 0..<20 {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let result = expression.evaluate(p)
                lock.lock()
                results.append(result)
                lock.unlock()
                done.signal()
            }
            done.wait()
        }
        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 == .success(true) }, "\(results)")
    }

    func testReleasedExpressionsAreFreed() {
        let engine = ProcessExpressionEngine()
        let p = item(9, "churn")
        // More distinct sources than the cache holds, so older ones are released and their slots reused.
        for i in 0..<200 {
            XCTAssertEqual(value(engine, "pid == \(i)", p), .success(i == 9))
        }
        var dropped: CompiledExpression<ProcessItem>? = engine.compile("pid > 0")
        weak var weakDropped = dropped
        dropped = nil
        for i in 0..<40 {
            _ = engine.compile("pid != \(i)")
        }
        XCTAssertNil(weakDropped)
        XCTAssertEqual(value(engine, "pid > 0", p), .success(true))
    }

    func testProcessMatcherModes() {
        let engine = ProcessExpressionEngine()
        let busy = item(10, "busy", cpu: 90)
        let idle = item(11, "idle", cpu: 1)
        let expression = ProcessMatcher("cpu > 50", mode: .javascript, engine: engine)
        XCTAssertTrue(expression.isExpression)
        XCTAssertTrue(expression.matches(busy))
        XCTAssertFalse(expression.matches(idle))
        let text = ProcessMatcher("idle", mode: .text, engine: engine)
        XCTAssertFalse(text.isExpression)
        XCTAssertTrue(text.matches(idle))
        XCTAssertFalse(text.matches(busy))
        XCTAssertFalse(ProcessMatcher("=cpu > 50", mode: .text, engine: engine).matches(busy), "text is text, = or not")
        XCTAssertTrue(ProcessMatcher("^bu.y$", mode: .regex, engine: engine).matches(busy))
        XCTAssertFalse(ProcessMatcher("bu.y", mode: .text, engine: engine).matches(busy))
        let blank = ProcessMatcher("  \n", mode: .javascript, engine: engine)
        XCTAssertTrue(blank.isEmpty, "an empty expression shows everything, like empty text")
        XCTAssertTrue(blank.matches(busy))
        let invalid = ProcessMatcher("cpu >", mode: .javascript, engine: engine)
        XCTAssertFalse(invalid.isValid)
        XCTAssertFalse(invalid.matches(busy))
        let noEngine = ProcessMatcher("cpu > 50", mode: .javascript, engine: nil)
        XCTAssertEqual(noEngine.error, "Expressions aren't available here")
        XCTAssertFalse(noEngine.matches(busy))
        XCTAssertTrue(ProcessMatcher("busy", mode: .text, engine: nil).matches(busy), "plain text needs no engine")
        XCTAssertEqual(ProcessExpressions.legacyExpression(in: "  =pid > 1 "), "pid > 1")
        XCTAssertNil(ProcessExpressions.legacyExpression(in: "pid=1"))
    }

    func testErrorSummary() {
        var errors = ExpressionErrors()
        XCTAssertNil(errors.summary(rows: "processes"))
        errors.record(ExpressionError(message: "TypeError: x"))
        XCTAssertEqual(errors.summary(rows: "processes"), "TypeError: x")
        errors.record(ExpressionError(message: "TypeError: y"))
        XCTAssertEqual(errors.summary(rows: "processes"), "TypeError: x (in 2 processes)")
    }
}
