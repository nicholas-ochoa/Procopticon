import XCTest
@testable import ProcopticonCore
import ProcopticonExpressions

final class AlertEvaluatorTests: XCTestCase {
    private func state(_ pid: Int32, _ comm: String, initial: Bool = true) -> ProcessState {
        let r = ProcessRecord(pid: pid, ppid: 1, pgid: pid, uid: 501, ruid: 501, rgid: 20, svuid: 501, status: 2,
                              flags: 0, nice: 0, tty: 0, startMicros: Int64(pid), comm: comm)
        return ProcessState(record: r, time: 0, initial: initial)
    }

    func testThresholdMustHoldForTheDuration() {
        var evaluator = AlertEvaluator()
        let rule = AlertRule(trigger: .cpu, threshold: 40, duration: 10)
        let busy = state(10, "busy")
        busy.cpu = 50
        let idle = state(11, "idle")
        let t0 = Date(timeIntervalSince1970: 1000)
        func run(_ t: Double) -> [Int32] {
            evaluator.evaluate([rule], items: [ProcessItem(busy), ProcessItem(idle)], cpuScale: 1, now: t0 + t).map(\.item.pid)
        }
        XCTAssertEqual(run(0), [])
        XCTAssertEqual(run(5), [])
        XCTAssertEqual(run(10), [10])
        XCTAssertEqual(run(11), [], "reported once per episode")
        busy.cpu = 10
        XCTAssertEqual(run(12), [])
        busy.cpu = 60
        XCTAssertEqual(run(13), [])
        XCTAssertEqual(run(23), [10], "a new episode is reported again")
    }

    func testCPUScaleAndProcessFilter() {
        var evaluator = AlertEvaluator()
        let rule = AlertRule(trigger: .cpu, process: "safari", threshold: 90)
        let safari = state(20, "Safari")
        safari.cpu = 10   // 10% of total capacity on a 16-core Mac = 160% of one core
        let other = state(21, "other")
        other.cpu = 10
        let alerts = evaluator.evaluate([rule], items: [ProcessItem(safari), ProcessItem(other)], cpuScale: 16)
        XCTAssertEqual(alerts.map(\.item.pid), [20])
    }

    func testStartsAndExits() {
        var evaluator = AlertEvaluator()
        let rules = [AlertRule(trigger: .started), AlertRule(trigger: .exited)]
        let old = state(30, "old")
        XCTAssertTrue(evaluator.evaluate(rules, items: [ProcessItem(old)], cpuScale: 1).isEmpty, "the first sample is the baseline")
        let new = state(31, "new", initial: false)
        let started = evaluator.evaluate(rules, items: [ProcessItem(old), ProcessItem(new)], cpuScale: 1)
        XCTAssertEqual(started.map(\.item.pid), [31])
        XCTAssertEqual(started.first?.rule.trigger, .started)
        XCTAssertTrue(evaluator.evaluate(rules, items: [ProcessItem(old), ProcessItem(new)], cpuScale: 1).isEmpty)
        new.markRemoved()
        let exited = evaluator.evaluate(rules, items: [ProcessItem(old), ProcessItem(new)], cpuScale: 1)
        XCTAssertEqual(exited.map(\.item.pid), [31])
        XCTAssertEqual(exited.first?.rule.trigger, .exited)
        XCTAssertTrue(evaluator.evaluate(rules, items: [ProcessItem(old), ProcessItem(new)], cpuScale: 1).isEmpty, "reported once")
    }

    func testDisabledAndInvalidRulesNeverFire() {
        var evaluator = AlertEvaluator()
        let busy = state(40, "busy")
        busy.cpu = 100
        let rules = [AlertRule(enabled: false, trigger: .cpu, threshold: 1),
                     AlertRule(trigger: .cpu, process: "/[/", threshold: 1)]
        XCTAssertTrue(evaluator.evaluate(rules, items: [ProcessItem(busy)], cpuScale: 1).isEmpty)
    }

    func testMatchesTriggerAndFilterModes() {
        var evaluator = AlertEvaluator(expressions: ProcessExpressionEngine())
        let busy = state(50, "busy")
        busy.cpu = 70
        let quiet = state(51, "quiet")
        quiet.cpu = 70
        let matches = AlertRule(trigger: .matches, process: "cpu > 60 && name == 'busy'", mode: .javascript, duration: 5)
        let filtered = AlertRule(trigger: .cpu, process: "^qu", mode: .regex, threshold: 60)
        let t0 = Date(timeIntervalSince1970: 2000)
        func run(_ t: Double) -> [String] {
            evaluator.evaluate([matches, filtered], items: [ProcessItem(busy), ProcessItem(quiet)], cpuScale: 1, now: t0 + t)
                .map { "\($0.rule.trigger.rawValue):\($0.item.pid)" }
        }
        XCTAssertEqual(run(0), ["cpu:51"])
        XCTAssertEqual(run(5), ["expression:50"], "the filter matched for its duration")
        busy.cpu = 10
        XCTAssertEqual(run(6), [])
        // A filter that doesn't compile never fires, and neither does an empty one, which would
        // match every process.
        let broken = [AlertRule(trigger: .matches, process: "cpu >", mode: .javascript),
                      AlertRule(trigger: .matches, process: "  ", mode: .javascript),
                      AlertRule(trigger: .matches, process: "")]
        XCTAssertTrue(evaluator.evaluate(broken, items: [ProcessItem(busy)], cpuScale: 1).isEmpty)
    }

    func testRulesDecodeAndSummarize() throws {
        let rule = AlertRule(trigger: .memory, process: "Xcode", threshold: 8192, duration: 60)
        let decoded = try JSONDecoder().decode(AlertRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(decoded, rule)
        XCTAssertEqual(rule.summary, "Memory > 8192 MB · for 1 minute · “Xcode”")
        let matches = AlertRule(trigger: .matches, process: "cpu > 50", mode: .javascript, duration: 30)
        XCTAssertEqual(matches.summary, "Matches · for 30 seconds · cpu > 50")
        XCTAssertEqual(AlertRule(trigger: .cpu, process: "^mds", mode: .regex).summary, "CPU > 0 % of one core · /^mds/")
    }

    func testRulesSavedBeforeModesDecode() throws {
        func decode(_ json: String) throws -> AlertRule {
            try JSONDecoder().decode(AlertRule.self, from: Data(json.utf8))
        }
        let id = UUID().uuidString
        let plain = try decode(#"{"id":"\#(id)","enabled":true,"trigger":"cpu","process":"Safari","regex":false,"threshold":90,"duration":60}"#)
        XCTAssertEqual(plain.mode, .text)
        XCTAssertEqual(plain.process, "Safari")
        let regex = try decode(#"{"id":"\#(id)","enabled":true,"trigger":"cpu","process":"^mds","regex":true,"threshold":90,"duration":60}"#)
        XCTAssertEqual(regex.mode, .regex)
        let equals = try decode(#"{"id":"\#(id)","enabled":true,"trigger":"memory","process":"= user == 'root'","regex":false,"threshold":1,"duration":0}"#)
        XCTAssertEqual(equals.mode, .javascript)
        XCTAssertEqual(equals.process, "user == 'root'")
        let condition = try decode(#"{"id":"\#(id)","enabled":true,"trigger":"expression","process":"","regex":false,"condition":"=cpu > 50","threshold":0,"duration":30}"#)
        XCTAssertEqual(condition.trigger, .matches)
        XCTAssertEqual(condition.mode, .javascript)
        XCTAssertEqual(condition.process, "cpu > 50")
    }
}
