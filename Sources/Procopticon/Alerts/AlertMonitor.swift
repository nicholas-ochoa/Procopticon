import AppKit
import Combine
import ProcopticonCore
import UserNotifications

/// Watches each sample for processes that meet an enabled rule, and reports them as notifications
/// and in the Event Log.
@MainActor
final class AlertMonitor {
    static let shared = AlertMonitor()

    private var evaluator = AlertEvaluator()
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    /// Recent notification times per rule, to rate-limit a rule that matches many processes.
    private var recent: [UUID: [Date]] = [:]
    private var authorizationRequested = false

    static let maxPerMinute = 5

    func start() {
        subscription = ProcessStore.shared.didSample
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.evaluate() }
        settingsSubscription = AppSettings.shared.$alertRules
            .receive(on: RunLoop.main)
            .sink { [weak self] rules in
                if rules.contains(where: \.enabled) { self?.requestAuthorization() }
            }
        Notifier.shared.install()
    }

    func requestAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        Notifier.shared.requestAuthorization()
    }

    private func evaluate() {
        let store = ProcessStore.shared
        let now = Date()
        let alerts = evaluator.evaluate(AppSettings.shared.alertRules, items: Array(store.items.values),
                                        cpuScale: Self.cpuScale, now: now)
        for alert in alerts {
            let (title, body) = Self.message(alert.rule, alert.item, heldFor: alert.heldFor)
            EventLog.shared.add(.alert, pid: alert.item.pid, "\(title). \(body)")
            var times = recent[alert.rule.id, default: []].filter { now.timeIntervalSince($0) < 60 }
            guard times.count < Self.maxPerMinute else { continue }
            times.append(now)
            recent[alert.rule.id] = times
            Notifier.shared.post(title: title, body: body, item: alert.item)
        }
    }

    /// Converts the CPU column's value to percent of one core.
    private static var cpuScale: Double {
        let store = ProcessStore.shared
        return store.scaleCPUToSystem ? Double(max(1, store.system.logicalCPUCount)) : 1
    }

    static func message(_ rule: AlertRule, _ item: ProcessItem, heldFor: TimeInterval) -> (String, String) {
        let name = item.displayName
        let cpuScale = Self.cpuScale
        let limit = "\(AlertRule.number(rule.threshold)) \(rule.trigger.unit)"
        let lasting = rule.duration > 0 && heldFor > 0 ? " for \(Fmt.relative(seconds: heldFor))" : ""
        let pid = "PID \(item.pid)"
        switch rule.trigger {
        case .cpu:
            return ("\(name) is using \(String(format: "%.0f", item.cpu * cpuScale))% CPU", "Above \(limit)\(lasting) · \(pid)")
        case .gpu:
            return ("\(name) is using \(String(format: "%.0f", item.gpu))% of the GPU", "Above \(limit)\(lasting) · \(pid)")
        case .memory:
            return ("\(name) is using \(Fmt.bytes(item.stats?.physFootprint ?? 0)) of memory", "Above \(limit)\(lasting) · \(pid)")
        case .disk:
            return ("\(name) is reading and writing \(Fmt.rate(item.ioTotalRate))", "Above \(limit)\(lasting) · \(pid)")
        case .network:
            return ("\(name) is transferring \(Fmt.rate(item.netTotalRate))", "Above \(limit)\(lasting) · \(pid)")
        case .notResponding:
            let hung = item.notRespondingSince.map { " for \(Fmt.relative(seconds: Date().timeIntervalSince($0)))" } ?? ""
            return ("\(name) is not responding", "Not responding\(hung) · \(pid)")
        case .preventingSleep:
            let what = item.sleepPrevention == .display ? "the display on" : "the Mac awake"
            let assertion = item.assertions.first { $0.sleepPrevention == item.sleepPrevention }.map { ": \($0.name)" } ?? ""
            return ("\(name) is keeping \(what)", "\(pid)\(lasting.isEmpty ? "" : " ·\(lasting)")\(assertion)")
        case .sensors:
            return ("\(name) is using the \(item.sensors.names.joined(separator: " and "))", "\(pid)\(lasting.isEmpty ? "" : " ·\(lasting)")")
        case .started:
            return ("\(name) started", [pid, item.record.commandLine].compactMap { $0 }.joined(separator: " · "))
        case .exited:
            let lifetime = Fmt.relative(seconds: (item.removedAt ?? Date()).timeIntervalSince1970 - item.record.startTime)
            return ("\(name) exited", "\(pid) · ran for \(lifetime)")
        }
    }
}

/// Delivers alerts through Notification Center. Clicking one shows the process in the main window.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Status {
        case unknown, allowed, denied, unavailable
    }

    /// Notification Center needs an app bundle; `swift run` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    @Published private(set) var status: Status = .unknown

    func install() {
        center?.delegate = self
        refreshStatus()
    }

    /// Asks once for permission to post notifications (macOS remembers the answer), then calls
    /// `completion`.
    func requestAuthorization(completion: (() -> Void)? = nil) {
        guard let center else {
            status = .unavailable
            completion?()
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in
                self.refreshStatus()
                completion?()
            }
        }
    }

    func refreshStatus() {
        guard let center else {
            status = .unavailable
            return
        }
        center.getNotificationSettings { settings in
            let s: Status
            switch settings.authorizationStatus {
            case .authorized, .provisional: s = .allowed
            case .denied: s = .denied
            default: s = .unknown
            }
            Task { @MainActor in self.status = s }
        }
    }

    func post(title: String, body: String, item: ProcessItem?) {
        let settings = AppSettings.shared
        if settings.alertSound {
            NSSound(named: "Funk")?.play()
        }
        guard settings.alertNotifications, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let item {
            content.userInfo = ["pid": Int(item.pid), "start": item.record.startMicros]
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Alerts show even while Procopticon is the active app.
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = (info["pid"] as? NSNumber)?.int32Value
        Task { @MainActor in
            NSApp.activate()
            if let pid, ProcessStore.shared.item(pid: pid) != nil {
                ProcessSelection.shared.reveal(pid: pid)
            } else {
                EventLogWindow.open()
            }
            completionHandler()
        }
    }
}
