import AppKit
import ProcopticonCore
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
    var active = true
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
        TableUnderToolbar {
            FilterBar {
                Text("Domain").foregroundStyle(.secondary).fixedSize()
                Picker(selection: $domainFilter) {
                    ForEach(DomainFilter.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Service domain")
                Toggle("Running only", isOn: $onlyRunning).toggleStyle(.checkbox).fixedSize()
                Toggle("Hide Apple services", isOn: $hideApple).toggleStyle(.checkbox).fixedSize()
            } trailing: {
                if store.loading { ProgressView().controlSize(.small) }
                Text("\(filtered.count) of \(store.items.count) services").foregroundStyle(.secondary).lineLimit(1)
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh services")
            }
        } table: { topInset in
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
                defaultSort: (column: "label", ascending: true),
                isActive: active,
                topInset: topInset)
        }
        .task(id: active) {
            // Poll launchd only while this tab is visible.
            guard active else { return }
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
        var label = TableColumnSpec<ServiceItem>.string("label", "Label", width: 300, help: "The launchd job's label") { $0.label }
        label.image = { s in
            NSImage(systemSymbolName: s.isRunning ? "gearshape.fill" : "gearshape", accessibilityDescription: nil)
        }
        label.tooltip = { s in [s.plistPath, s.executable].compactMap { $0 }.joined(separator: "\n") }
        return [
            label,
            .number("pid", "PID", width: 60,
                    help: "Process ID of the job's running process",
                    value: { $0.pid ?? 0 }, text: { $0.pid.map { "\($0)" } ?? "" }),
            .string("status", "Status", width: 90, help: "Running, Stopped, Disabled, or Not loaded into launchd") { $0.statusDescription },
            .string("domain", "Domain", width: 120, help: "System (launch daemons) or a user's session (launch agents)") { $0.domain.displayName },
            .string("kind", "Type", width: 110, help: "Launch daemon, launch agent, login item, or on-demand XPC service") { $0.kind.rawValue },
            .string("start", "Start", width: 120,
                    help: "When launchd starts the job: at load, kept alive, on an interval, or on demand") { $0.startTypeDescription },
            .string("exit", "Last exit", width: 70,
                    help: "How the job's last run ended (exit code or signal)") { $0.lastExitStatus == "-" ? "" : $0.lastExitStatus },
            .string("enabled", "Enabled", width: 60,
                    help: "Whether the job is enabled; launchd doesn't load disabled jobs") { $0.disabled == true ? "No" : "Yes" },
            .string("program", "Program", width: 320, help: "The executable launchd runs for the job") { $0.executable ?? "" },
            .string("plist", "Property list", width: 300, visible: false, help: "The job's property list file") { $0.plistPath ?? "" },
            .string("user", "Run as user", width: 90, visible: false, help: "The user the job runs as (its UserName key)") { $0.userName ?? "" },
            .string("mach", "Mach services", width: 200, visible: false,
                    help: "Mach services the job provides; launchd starts the job when one is looked up") { $0.machServices.joined(separator: ", ") },
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
        WindowManager.shared.show(id: "service-\(s.id)", title: "\(s.label) Properties", size: NSSize(width: 820, height: 580),
                                  fullSizeContent: true) {
            ServicePropertiesView(service: s)
        }
    }
}

struct ServicePropertiesView: View {
    let service: ServiceItem
    @ObservedObject private var store = ServiceStore.shared
    @State private var page = Page.general
    @State private var plistText = ""

    enum Page: String, SidebarPage {
        case general = "General"
        case launchdState = "launchd State"
        case propertyList = "Property List"

        var id: String { rawValue }
        var title: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "info.circle"
            case .launchdState: return "gearshape.2"
            case .propertyList: return "doc.text"
            }
        }
    }

    /// The service as launchd last reported it, so the page follows starts and stops.
    private var current: ServiceItem {
        store.items.first { $0.id == service.id } ?? service
    }

    var body: some View {
        SidebarPagesView(selection: $page) { page in
            switch page {
            case .general: general
            case .launchdState: TextReportView(title: service.label) { await ServiceProvider.details(of: current) }
            case .propertyList: propertyList
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .task { store.refreshIfNeeded() }
    }

    private var general: some View {
        let s = current
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(s)
                control(s)
                details(s)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private func header(_ s: ServiceItem) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.label).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("\(s.kind.rawValue) · \(s.domain.displayName)").foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(text: s.statusDescription, color: statusColor(s))
        }
    }

    private func statusColor(_ s: ServiceItem) -> Color {
        if s.isRunning { return .green }
        if !s.loaded { return .secondary }
        if s.disabled == true { return .orange }
        return .gray
    }

    // MARK: Control

    /// One row per thing that can be changed: its state, then the actions that apply to it.
    private func control(_ s: ServiceItem) -> some View {
        SectionBox(title: "Control") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    rowLabel("Process")
                    Text(s.isRunning ? "Running, PID " + String(s.pid ?? 0) : "Not running")
                    HStack(spacing: 6) {
                        Button { run(.start) } label: { Label("Start", systemImage: "play.fill") }
                            .disabled(s.isRunning)
                            .help("Start the service now (launchctl kickstart)")
                        Button { run(.stop) } label: { Label("Stop", systemImage: "stop.fill") }
                            .disabled(!s.isRunning)
                            .help("Send the service SIGTERM (launchctl kill)")
                        Button { run(.restart) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                            .disabled(!s.loaded)
                            .help("Stop the service if it runs, then start it (launchctl kickstart -k)")
                    }
                }
                GridRow {
                    rowLabel("launchd")
                    Text(s.loaded ? "Loaded in \(s.domain.target)" : "Not loaded")
                    if s.loaded {
                        Button { run(.unload) } label: { Label("Unload", systemImage: "eject") }
                            .help("Remove the job from launchd until it's loaded again (launchctl bootout)")
                    } else {
                        Button { run(.load) } label: { Label("Load", systemImage: "square.and.arrow.down") }
                            .disabled(s.plistPath == nil)
                            .help(s.plistPath == nil ? "There's no property list on disk to load" : "Load the job from its property list (launchctl bootstrap)")
                    }
                }
                GridRow {
                    rowLabel("Startup")
                    Text(s.disabled == true ? "Disabled: launchd won't load it" : "Enabled")
                    if s.disabled == true {
                        Button { run(.enable) } label: { Label("Enable", systemImage: "checkmark.circle") }
                            .help("Let launchd load the job (launchctl enable)")
                    } else {
                        Button { run(.disable) } label: { Label("Disable", systemImage: "nosign") }
                            .help("Keep launchd from loading the job, including at the next login or boot (launchctl disable)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if s.domain.requiresRoot, Elevation.shared.mode == .standard {
                Label("Changing system services asks for administrator authorization.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func run(_ action: ServiceProvider.Action) {
        ServiceActions.run(action, [current])
    }

    // MARK: Details

    private func details(_ s: ServiceItem) -> some View {
        SectionBox(title: "Service") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                LinkedInfoRow("Label", s.label) {
                    AccessoryButton("Copy label", "doc.on.doc") { ProcessActions.copy(s.label) }
                }
                InfoRow("Domain", "\(s.domain.displayName) (\(s.domain.target))")
                InfoRow("Type", s.kind.rawValue)
                LinkedInfoRow("PID", s.pid.map { "\($0)" } ?? "") {
                    if let pid = s.pid, pid > 0 {
                        AccessoryButton("Process properties", "info.circle") {
                            if let item = ProcessStore.shared.item(pid: pid) { PropertiesWindow.open(item) }
                        }
                        AccessoryButton("Show in the process list", "list.bullet.indent") { ProcessSelection.shared.reveal(pid: pid) }
                    }
                }
                InfoRow("Last exit status", s.lastExitStatus)
                InfoRow("Start", s.startTypeDescription)
                InfoRow("Run as user", s.userName ?? "")
                LinkedInfoRow("Program", s.executable ?? "") {
                    if let exe = s.executable, FileManager.default.fileExists(atPath: exe) {
                        AccessoryButton("Inspect executable", "magnifyingglass") { InspectorWindow.open(path: exe) }
                        AccessoryButton("Reveal in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exe)]) }
                    }
                }
                InfoRow("Arguments", s.arguments.shellJoined)
                LinkedInfoRow("Property list", s.plistPath ?? "") {
                    if let plist = s.plistPath {
                        AccessoryButton("Show contents", "doc.text") { page = .propertyList }
                        AccessoryButton("Reveal in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)]) }
                    }
                }
                InfoRow("Mach services", s.machServices.joined(separator: "\n"))
            }
        }
    }

    private var propertyList: some View {
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

    /// The program's app icon when it lives in a bundle, otherwise a generic service icon.
    private var icon: NSImage {
        if let exe = service.executable, let bundle = BundleInfoCache.outermostApplicationPath(exe) ?? BundleInfoCache.enclosingBundlePath(exe) {
            return NSWorkspace.shared.icon(forFile: bundle)
        }
        return NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? ProcessIcons.executable
    }
}

/// Capsule with a colored dot, for a status at a glance.
private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// `InfoRow` with small buttons after the value for what can be done with it.
private struct LinkedInfoRow<Accessories: View>: View {
    let label: String
    let value: String
    @ViewBuilder var accessories: Accessories

    init(_ label: String, _ value: String, @ViewBuilder accessories: () -> Accessories) {
        self.label = label
        self.value = value
        self.accessories = accessories()
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.isEmpty ? "—" : value)
                    .textSelection(.enabled)
                    .lineLimit(4)
                accessories
            }
            .gridColumnAlignment(.leading)
        }
    }
}

/// Icon-only borderless button with its title as the tooltip.
private struct AccessoryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}
