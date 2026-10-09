import Foundation

/// A condition on processes that raises a notification when it's met.
public struct AlertRule: Codable, Identifiable, Hashable, Sendable {
    public enum Trigger: String, Codable, CaseIterable, Identifiable, Sendable {
        case cpu, memory, disk, network, gpu
        case started, exited, notResponding, preventingSleep, sensors
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .cpu: return "CPU usage is above"
            case .memory: return "Memory is above"
            case .disk: return "Disk read + write rate is above"
            case .network: return "Network receive + send rate is above"
            case .gpu: return "GPU usage is above"
            case .started: return "A process starts"
            case .exited: return "A process exits"
            case .notResponding: return "An application stops responding"
            case .preventingSleep: return "A process keeps the Mac awake"
            case .sensors: return "A process uses the microphone, camera or screen recording"
            }
        }

        /// Short form for rule summaries.
        public var shortTitle: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .disk: return "Disk"
            case .network: return "Network"
            case .gpu: return "GPU"
            case .started: return "Starts"
            case .exited: return "Exits"
            case .notResponding: return "Not responding"
            case .preventingSleep: return "Preventing sleep"
            case .sensors: return "Microphone, camera or screen"
            }
        }

        public var hasThreshold: Bool {
            switch self {
            case .cpu, .memory, .disk, .network, .gpu: return true
            default: return false
            }
        }

        /// Whether the condition can last, so the rule can wait for it to persist.
        public var hasDuration: Bool {
            switch self {
            case .started, .exited: return false
            default: return true
            }
        }

        /// The threshold's unit as shown in the editor.
        public var unit: String {
            switch self {
            case .cpu: return "% of one core"
            case .gpu: return "%"
            case .memory: return "MB"
            case .disk, .network: return "MB/s"
            default: return ""
            }
        }

        public var defaultThreshold: Double {
            switch self {
            case .cpu: return 90
            case .gpu: return 80
            case .memory: return 4096
            case .disk, .network: return 50
            default: return 0
            }
        }
    }

    public var id = UUID()
    public var enabled = true
    public var trigger: Trigger
    /// Search text selecting the processes (name, PID, path, command line, user, bundle ID); empty
    /// for any process. `/pattern/` is a regular expression, as in every search field.
    public var process = ""
    public var regex = false
    /// In the trigger's unit (see `Trigger.unit`).
    public var threshold: Double = 0
    /// Seconds the condition must hold before the alert.
    public var duration: Double = 0

    public init(id: UUID = UUID(), enabled: Bool = true, trigger: Trigger, process: String = "", regex: Bool = false,
                threshold: Double = 0, duration: Double = 0) {
        self.id = id
        self.enabled = enabled
        self.trigger = trigger
        self.process = process
        self.regex = regex
        self.threshold = threshold
        self.duration = duration
    }

    public var summary: String {
        var parts: [String] = []
        if trigger.hasThreshold {
            parts.append("\(trigger.shortTitle) > \(Self.number(threshold)) \(trigger.unit)")
        } else {
            parts.append(trigger.shortTitle)
        }
        if trigger.hasDuration, duration > 0 {
            parts.append("for \(Self.durationTitle(duration))")
        }
        let p = process.trimmingCharacters(in: .whitespaces)
        parts.append(p.isEmpty ? "any process" : "“\(p)”")
        return parts.joined(separator: " · ")
    }

    public static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    public static let durations: [Double] = [0, 5, 10, 30, 60, 120, 300, 600, 1800, 3600]

    public static func durationTitle(_ seconds: Double) -> String {
        if seconds <= 0 { return "Immediately" }
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        if seconds < 3600 { return seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes" }
        return seconds == 3600 ? "1 hour" : "\(Int(seconds / 3600)) hours"
    }

    public static func new(_ trigger: Trigger = .cpu) -> AlertRule {
        AlertRule(trigger: trigger, threshold: trigger.defaultThreshold, duration: trigger.hasDuration ? 30 : 0)
    }

    public static let examples: [AlertRule] = [
        AlertRule(enabled: false, trigger: .notResponding, duration: 10),
        AlertRule(enabled: false, trigger: .cpu, threshold: 90, duration: 60),
        AlertRule(enabled: false, trigger: .memory, threshold: 8192, duration: 0),
    ]
}

/// Decides, sample by sample, which processes meet which rules. Pure bookkeeping: delivering the
/// alerts is up to the caller.
public struct AlertEvaluator {
    public struct Alert {
        public var rule: AlertRule
        public var item: ProcessItem
        /// How long the condition had held (0 for start and exit rules).
        public var heldFor: TimeInterval
    }

    private struct Episode: Hashable {
        var rule: UUID
        var process: ProcessKey
    }

    /// When each (rule, process) condition started holding.
    private var since: [Episode: Date] = [:]
    /// Conditions already reported; cleared when the condition stops holding.
    private var reported = Set<Episode>()
    /// Processes in the previous sample, and which of them had exited, for start and exit rules.
    private var known = Set<ProcessKey>()
    private var exited = Set<ProcessKey>()
    private var hasBaseline = false
    private var matchers: [UUID: (text: String, regex: Bool, matcher: SearchMatcher)] = [:]

    public init() {}

    /// `cpuScale` turns the CPU column's value into percent of one core.
    public mutating func evaluate(_ rules: [AlertRule], items: [ProcessItem], cpuScale: Double, now: Date = Date()) -> [Alert] {
        defer {
            known = Set(items.map(\.key))
            exited = Set(items.filter(\.isRemoved).map(\.key))
            hasBaseline = true
        }
        let rules = rules.filter(\.enabled)
        guard !rules.isEmpty else {
            since.removeAll()
            reported.removeAll()
            matchers.removeAll()
            return []
        }
        var alerts: [Alert] = []
        var active = Set<Episode>()
        for rule in rules {
            let matcher = matcher(for: rule)
            guard matcher.isValid else { continue }
            for item in items where matcher.isEmpty || item.matches(matcher) {
                switch rule.trigger {
                case .started:
                    if hasBaseline, !item.isInitial, !known.contains(item.key) {
                        alerts.append(Alert(rule: rule, item: item, heldFor: 0))
                    }
                    continue
                case .exited:
                    if hasBaseline, item.isRemoved, !exited.contains(item.key) {
                        alerts.append(Alert(rule: rule, item: item, heldFor: 0))
                    }
                    continue
                default:
                    break
                }
                guard !item.isRemoved, Self.holds(rule, item, cpuScale: cpuScale) else { continue }
                let episode = Episode(rule: rule.id, process: item.key)
                active.insert(episode)
                let start = since[episode] ?? now
                since[episode] = start
                if !reported.contains(episode), now.timeIntervalSince(start) >= rule.duration {
                    reported.insert(episode)
                    alerts.append(Alert(rule: rule, item: item, heldFor: now.timeIntervalSince(start)))
                }
            }
        }
        // A condition that stopped holding is reported again the next time it holds.
        since = since.filter { active.contains($0.key) }
        reported.formIntersection(active)
        let ids = Set(rules.map(\.id))
        matchers = matchers.filter { ids.contains($0.key) }
        return alerts
    }

    private mutating func matcher(for rule: AlertRule) -> SearchMatcher {
        if let cached = matchers[rule.id], cached.text == rule.process, cached.regex == rule.regex {
            return cached.matcher
        }
        let m = SearchMatcher(rule.process, regex: rule.regex)
        matchers[rule.id] = (rule.process, rule.regex, m)
        return m
    }

    static func holds(_ rule: AlertRule, _ item: ProcessItem, cpuScale: Double) -> Bool {
        let mb = 1024.0 * 1024
        switch rule.trigger {
        case .cpu: return item.cpu * cpuScale > rule.threshold
        case .gpu: return item.gpu > rule.threshold
        case .memory: return Double(item.stats?.physFootprint ?? 0) > rule.threshold * mb
        case .disk: return item.ioTotalRate > rule.threshold * mb
        case .network: return item.netTotalRate > rule.threshold * mb
        case .notResponding: return item.isNotResponding
        case .preventingSleep: return item.sleepPrevention != nil
        case .sensors: return !item.sensors.isEmpty
        case .started, .exited: return false
        }
    }
}
