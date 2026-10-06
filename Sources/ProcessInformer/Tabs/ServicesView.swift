import AppKit
import InformerCore
import SwiftUI

final class ServiceStore: ObservableObject {
    static let shared = ServiceStore()
    @Published private(set) var items: [ServiceItem] = []
    @Published private(set) var revision = 0
    @Published private(set) var loading = false
    private var lastLoad = Date.distantPast
    private var previousIds = Set<String>()
    private(set) var newIds = Set<String>()

    func refreshIfNeeded() {
        if Date().timeIntervalSince(lastLoad) > 5 {
            refresh()
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = ServiceProvider.list()
            DispatchQueue.main.async {
                let ids = Set(list.map(\.id))
                if !self.items.isEmpty {
                    let old = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    for s in list {
                        let wasRunning = old[s.id]?.isRunning ?? false
                        if s.isRunning, !wasRunning {
                            EventLog.shared.add(.serviceStarted, pid: s.pid, "\(s.label) (\(s.domain.target)) started, PID \(s.pid ?? 0)")
                        } else if !s.isRunning, wasRunning {
                            EventLog.shared.add(.serviceStopped, "\(s.label) (\(s.domain.target)) stopped, last exit \(s.lastExitStatus)")
                        }
                    }
                }
                if !self.previousIds.isEmpty {
                    self.newIds = ids.subtracting(self.previousIds)
                }
                self.previousIds = ids
                self.items = list
                self.loading = false
                self.lastLoad = Date()
                self.revision &+= 1
            }
        }
    }
}

struct ServicesView: View {
    @ObservedObject private var store = ServiceStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Binding var search: String
    @State private var domainFilter = DomainFilter.all
    @State private var hideApple = false
    @State private var onlyRunning = false

    enum DomainFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case system = "System"
        case user = "User"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Domain", selection: $domainFilter) {
                    ForEach(DomainFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Toggle("Running only", isOn: $onlyRunning).toggleStyle(.checkbox)
                Toggle("Hide Apple services", isOn: $hideApple).toggleStyle(.checkbox)
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Text("\(filtered.count) of \(store.items.count) services").foregroundStyle(.secondary)
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh services")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            OutlineTable(
                roots: filtered,
                children: nil,
                revision: store.revision &+ search.hashValue &+ (settings.searchUsesRegex ? 4 : 0) &+ domainFilter.hashValue &+ (hideApple ? 1 : 0) &+ (onlyRunning ? 2 : 0),
                columns: Self.columns,
                autosaveName: "ServicesTable",
                key: { AnyHashable($0.id) },
                rowStyle: { style($0) },
                menu: { ServiceActions.menu(for: $0) },
                onDoubleClick: { ServicePropertiesWindow.open($0) },
                defaultSort: (column: "label", ascending: true))
        }
        .task {
            store.refreshIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !ProcessStore.shared.paused { store.refresh() }
            }
        }
    }

    private var filtered: [ServiceItem] {
        let m = settings.matcher(search)
        return store.items.filter { s in
            switch domainFilter {
            case .system: if s.domain != .system { return false }
            case .user: if s.domain == .system { return false }
            case .all: break
            }
            if hideApple, s.isApple { return false }
            if onlyRunning, !s.isRunning { return false }
            return m.matchesAny(s.label, s.executable, s.plistPath) || (s.pid.map { m.matchesIdentifier("\($0)") } ?? false)
        }
    }

    private func style(_ s: ServiceItem) -> RowStyle? {
        let h = AppSettings.shared.highlights
        if store.newIds.contains(s.id), let n = h[.new], n.enabled {
            return RowStyle(background: n.color.withAlphaComponent(0.45))
        }
        if s.disabled == true, let c = h[.suspended], c.enabled {
            return RowStyle(background: c.color.withAlphaComponent(0.22))
        }
        if s.isRunning, let c = h[.daemons], c.enabled {
            return RowStyle(background: c.color.withAlphaComponent(0.22))
        }
        return nil
    }

    static let columns: [TableColumnSpec<ServiceItem>] = {
        var label = TableColumnSpec<ServiceItem>.string("label", "Label", width: 300) { $0.label }
        label.image = { s in
            NSImage(systemSymbolName: s.isRunning ? "gearshape.fill" : "gearshape", accessibilityDescription: nil)
        }
        label.tooltip = { s in [s.plistPath, s.executable].compactMap { $0 }.joined(separator: "\n") }
        return [
            label,
            .number("pid", "PID", width: 60, value: { $0.pid ?? 0 }, text: { $0.pid.map { "\($0)" } ?? "" }),
            .string("status", "Status", width: 90) { $0.statusDescription },
            .string("domain", "Domain", width: 120) { $0.domain.displayName },
            .string("kind", "Type", width: 110) { $0.kind.rawValue },
            .string("start", "Start", width: 120) { $0.startTypeDescription },
            .string("exit", "Last exit", width: 70) { $0.lastExitStatus == "-" ? "" : $0.lastExitStatus },
            .string("enabled", "Enabled", width: 60) { $0.disabled == true ? "No" : "Yes" },
            .string("program", "Program", width: 320) { $0.executable ?? "" },
            .string("plist", "Property list", width: 300, visible: false) { $0.plistPath ?? "" },
            .string("user", "Run as user", width: 90, visible: false) { $0.userName ?? "" },
            .string("mach", "Mach services", width: 200, visible: false) { $0.machServices.joined(separator: ", ") },
        ]
    }()
}

@MainActor
enum ServiceActions {
    static func menu(for items: [ServiceItem]) -> NSMenu {
        let m = NSMenu()
        guard let first = items.first else { return m }
        m.add("Start", image: "play") { run(.start, items) }
        m.add("Stop", image: "stop") { run(.stop, items) }
        m.add("Restart", image: "arrow.clockwise") { run(.restart, items) }
        m.addItem(.separator())
        m.add("Load (bootstrap)", enabled: first.plistPath != nil && !first.loaded) { run(.load, items) }
        m.add("Unload (bootout)", enabled: first.loaded) { run(.unload, items) }
        m.add("Enable") { run(.enable, items) }
        m.add("Disable") { run(.disable, items) }
        m.addItem(.separator())
        if let pid = first.pid {
            m.add("Go to Process") { ProcessSelection.shared.reveal(pid: pid) }
        }
        if let plist = first.plistPath {
            m.add("Reveal Property List in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)]) }
        }
        if let exe = first.executable, FileManager.default.fileExists(atPath: exe) {
            m.add("Inspect Executable…") { InspectorWindow.open(path: exe) }
        }
        m.add("Copy Label") { ProcessActions.copy(items.map(\.label).joined(separator: "\n")) }
        m.addItem(.separator())
        m.add("Properties", image: "info.circle") { ServicePropertiesWindow.open(first) }
        return m
    }

    static func run(_ action: ServiceProvider.Action, _ items: [ServiceItem]) {
        let destructive = [.stop, .unload, .disable].contains(action)
        if destructive {
            let names = items.count == 1 ? items[0].label : "\(items.count) services"
            var warning = ""
            if items.contains(where: { $0.isApple }) {
                warning = "\n\nApple services are part of macOS; stopping or disabling them can break system features."
            }
            guard Alerts.confirm("Do you want to \(action.rawValue.lowercased()) \(names)?",
                                 message: "launchctl will be used to \(action.rawValue.lowercased()) the service." + warning,
                                 button: action.rawValue) else { return }
        }
        Task {
            var failures: [String] = []
            for s in items {
                if case .failure(let e) = await ServiceProvider.perform(action, on: s), e != .cancelled {
                    failures.append("\(s.label): \(e.message)")
                }
            }
            if !failures.isEmpty {
                Alerts.error("Unable to \(action.rawValue.lowercased()) the service", failures.joined(separator: "\n"))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            ServiceStore.shared.refresh()
        }
    }
}

@MainActor
enum ServicePropertiesWindow {
    static func open(_ s: ServiceItem) {
        WindowManager.shared.show(id: "service-\(s.id)", title: "\(s.label) Properties", size: NSSize(width: 720, height: 600)) {
            ServicePropertiesView(service: s)
        }
    }
}

struct ServicePropertiesView: View {
    let service: ServiceItem
    @State private var tab = 0
    @State private var plistText = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text("launchd State").tag(1)
                Text("Property List").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case 0:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionBox(title: "Service") {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                                InfoRow("Label", service.label)
                                InfoRow("Domain", "\(service.domain.displayName) (\(service.domain.target))")
                                InfoRow("Type", service.kind.rawValue)
                                InfoRow("Status", service.statusDescription)
                                InfoRow("PID", service.pid.map { "\($0)" } ?? "")
                                InfoRow("Last exit status", service.lastExitStatus)
                                InfoRow("Enabled", service.disabled == true ? "No" : "Yes")
                                InfoRow("Start", service.startTypeDescription)
                                InfoRow("Run as user", service.userName ?? "")
                                InfoRow("Program", service.executable ?? "")
                                InfoRow("Arguments", service.arguments.shellJoined)
                                InfoRow("Property list", service.plistPath ?? "")
                                InfoRow("Mach services", service.machServices.joined(separator: "\n"))
                            }
                        }
                        HStack {
                            ForEach(ServiceProvider.Action.allCases, id: \.self) { action in
                                Button(action.rawValue) { ServiceActions.run(action, [service]) }
                            }
                        }
                        if service.domain.requiresRoot, Elevation.shared.mode == .standard {
                            Label("Controlling system services requires administrator authorization.", systemImage: "lock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
            case 1:
                TextReportView(title: service.label) { await ServiceProvider.details(of: service) }
            default:
                MonospacedTextView(text: plistText)
                    .task {
                        if let p = service.plistPath, let data = FileManager.default.contents(atPath: p),
                           let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
                           let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) {
                            plistText = String(decoding: xml, as: UTF8.self)
                        } else {
                            plistText = "No property list on disk for this job (it may be registered by an application at runtime)."
                        }
                    }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
