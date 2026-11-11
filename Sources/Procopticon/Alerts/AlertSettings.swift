import AppKit
import ProcopticonCore
import SwiftUI

/// Settings ▸ Alerts: the alert rules, and how alerts are delivered.
struct AlertSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var notifier = Notifier.shared
    @State private var selection: AlertRule.ID?

    var body: some View {
        VStack(spacing: 0) {
            delivery
            HStack(alignment: .top, spacing: 0) {
                ruleList
                Group {
                    if let current = settings.alertRules.first(where: { $0.id == selection }) {
                        // Bound by the rule's id, not its place in the list: a field that commits
                        // its text as the rule is removed would write past the end of the list,
                        // or into the rule that moved into its place.
                        AlertRuleEditor(rule: Binding(
                            get: { settings.alertRules.first { $0.id == current.id } ?? current },
                            set: { edited in
                                if let index = settings.alertRules.firstIndex(where: { $0.id == current.id }) {
                                    settings.alertRules[index] = edited
                                }
                            }))
                    } else {
                        VStack(spacing: 8) {
                            Text("Select a rule to edit it, or click + to add one.").foregroundStyle(.secondary)
                            Text("Each alert is also recorded in the Event Log (⌥⌘L).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .settingsPane()
        .onAppear {
            notifier.refreshStatus()
            if selection == nil { selection = settings.alertRules.first?.id }
        }
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                Toggle("Show notifications", isOn: $settings.alertNotifications)
                    .help("Post a notification for each alert; clicking it shows the process")
                Toggle("Play a sound", isOn: $settings.alertSound)
                    .help("Play the Funk sound for each alert")
                Spacer()
            }
            switch notifier.status {
            case .denied:
                HStack {
                    Label("Notifications for Procopticon are turned off in System Settings.", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                    Button("Open Notification Settings…") {
                        let id = Bundle.main.bundleIdentifier ?? ""
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .font(.caption)
            case .unavailable:
                Label("Notifications need Procopticon to run as an app; alerts go to the Event Log.", systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.secondary)
            case .unknown, .allowed:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($settings.alertRules) { $rule in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Toggle("", isOn: $rule.enabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help(rule.enabled ? "Turn this rule off" : "Turn this rule on")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.trigger.title)
                            Text(rule.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .opacity(rule.enabled ? 1 : 0.55)
                    }
                    .tag(rule.id)
                }
                .onMove { settings.alertRules.move(fromOffsets: $0, toOffset: $1) }
            }
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 2) {
                Button { add() } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                    .help("Add a rule")
                Button { remove() } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                    .disabled(selection == nil)
                    .help("Delete the selected rule")
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square").frame(width: 22, height: 20) }
                    .disabled(selection == nil)
                    .help("Duplicate the selected rule")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(width: 240)
        .padding([.leading, .vertical], 20)
    }

    private func add() {
        let rule = AlertRule.new()
        settings.alertRules.append(rule)
        selection = rule.id
    }

    private func remove() {
        guard let i = settings.alertRules.firstIndex(where: { $0.id == selection }) else { return }
        settings.alertRules.remove(at: i)
        selection = settings.alertRules.indices.contains(i) ? settings.alertRules[i].id : settings.alertRules.last?.id
    }

    private func duplicate() {
        guard let rule = settings.alertRules.first(where: { $0.id == selection }) else { return }
        var copy = rule
        copy.id = UUID()
        settings.alertRules.append(copy)
        selection = copy.id
    }
}

struct AlertRuleEditor: View {
    @Binding var rule: AlertRule

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Enabled", isOn: $rule.enabled)
                    Picker("Alert when", selection: Binding(get: { rule.trigger }, set: { setTrigger($0) })) {
                        ForEach(AlertRule.Trigger.allCases) { Text($0.title).tag($0) }
                    }
                    if rule.trigger.hasThreshold {
                        LabeledContent("Threshold") {
                            HStack(spacing: 6) {
                                TextField("Threshold", value: $rule.threshold, format: .number)
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Text(rule.trigger.unit).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if rule.trigger.hasDuration {
                        Picker("For at least", selection: $rule.duration) {
                            ForEach(durations, id: \.self) { Text(AlertRule.durationTitle($0)).tag($0) }
                        }
                    }
                } footer: {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
                Section(rule.trigger == .matches ? "Filter" : "Processes") {
                    FilterEditor(text: $rule.process, mode: $rule.mode, emptyStatus: rule.trigger == .matches
                        ? "This rule needs a filter: it alerts for the processes that match it."
                        : "Watches every process.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Send Test Alert") {
                    let summary = rule.summary
                    Notifier.shared.requestAuthorization {
                        Notifier.shared.post(title: "Procopticon test alert", body: summary, item: nil)
                    }
                }
                .help("Post a sample notification to check how alerts appear")
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    /// The standard durations, plus the rule's own if it's something else.
    private var durations: [Double] {
        AlertRule.durations.contains(rule.duration) ? AlertRule.durations : (AlertRule.durations + [rule.duration]).sorted()
    }

    private func setTrigger(_ trigger: AlertRule.Trigger) {
        guard trigger != rule.trigger else { return }
        rule.trigger = trigger
        rule.threshold = trigger.defaultThreshold
        if !trigger.hasDuration {
            rule.duration = 0
        }
    }

    private var explanation: String {
        switch rule.trigger {
        case .cpu: return "100% is one core fully busy, whatever the CPU column shows."
        case .memory: return "The process's memory footprint, as in the Memory column."
        case .disk, .network, .gpu: return "Averaged over each update interval."
        case .started, .exited: return "Alerts once per process. A rule matching many processes notifies at most \(AlertMonitor.maxPerMinute) times a minute; the Event Log records them all."
        case .notResponding: return "When the window server finds the app hung (the spinning wait cursor)."
        case .preventingSleep: return "When the process holds a power assertion that keeps the Mac or its display awake."
        case .sensors: return "The microphone from Core Audio; the camera and screen recording from Control Center's privacy indicators."
        case .matches: return "When a process matches the filter below, for at least the time above. For a condition on its values, pick JavaScript, as in cpu > 50 && memory > 2 * GB."
        }
    }
}
