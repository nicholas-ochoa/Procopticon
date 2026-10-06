import AppKit
import InformerCore
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case services = "Services"
    case network = "Network"
    case disk = "Disk"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .processes: return "list.bullet.indent"
        case .services: return "gearshape.2"
        case .network: return "network"
        case .disk: return "internaldrive"
        }
    }
}

extension Notification.Name {
    static let showTab = Notification.Name("ProcessInformer.ShowTab")
    static let focusSearch = Notification.Name("ProcessInformer.FocusSearch")
}

struct MainView: View {
    @ObservedObject private var store = ProcessStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("mainTab") private var tab: MainTab = .processes
    @State private var processSearch = ""
    @State private var otherSearch = ""
    @State private var elevationRevision = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .processes: ProcessTreeView()
                case .services: ServicesView(search: $otherSearch)
                case .network: NetworkView(search: $otherSearch)
                case .disk: DiskView(search: $otherSearch)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if settings.showStatusBar {
                Divider()
                StatusBarView(elevationRevision: elevationRevision,
                              searchError: tab == .processes ? store.filterError : settings.matcher(otherSearch).error,
                              showFilterSummary: tab == .processes)
            }
        }
        .navigationTitle("Process Informer")
        .toolbar(id: "main") { toolbar }
        .toolbar(removing: .title)
        .searchable(text: tab == .processes ? $processSearch : $otherSearch, placement: .toolbar,
                    prompt: (tab == .processes ? "Search processes" : "Search \(tab.rawValue.lowercased())")
                        + (settings.searchUsesRegex ? " (regex)" : ""))
        .searchFocused($searchFocused)
        .onChange(of: processSearch) { _, new in store.filter.text = new }
        .onChange(of: tab) { otherSearch = "" }
        .onReceive(NotificationCenter.default.publisher(for: .showTab)) { n in
            if let t = n.object as? MainTab { tab = t }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: Elevation.didChangeNotification)) { _ in
            elevationRevision &+= 1
        }
        .onReceive(store.$revision) { _ in
            // Keep the filter text in sync if something else cleared it (e.g. "Go to process").
            if store.filter.text != processSearch, tab == .processes {
                processSearch = store.filter.text
            }
        }
        .onAppear { SettingsOpener.action = { openSettings() } }
        .background(WindowAccessor { window in
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.level = settings.alwaysOnTop ? .floating : .normal
            window.setFrameAutosaveName("MainWindow")
        })
    }

    private var subtitle: String {
        _ = elevationRevision
        switch Elevation.shared.mode {
        case .root: return "Running as root"
        case .helper: return "Elevated"
        case .standard: return ""
        }
    }

    /// Customizable toolbar (View ▸ Customize Toolbar…). The title and tab picker stay fixed on
    /// the left; everything else can be removed, reordered or added from the palette.
    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        fixedToolbarItems
        filterToolbarItems
        actionToolbarItems
        optionalToolbarItems
        moreOptionalToolbarItems
    }

    @ToolbarContentBuilder
    private var fixedToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "title", placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Process Informer").font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .padding(.horizontal, 6)
        }
        .customizationBehavior(.disabled)
        ToolbarItem(id: "tabs", placement: .navigation) {
            Picker("View", selection: $tab) {
                ForEach(MainTab.allCases) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleOnly)
        }
        .customizationBehavior(.disabled)
    }

    /// Process quick filters (enabled on the Processes tab).
    @ToolbarContentBuilder
    private var filterToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "apps", placement: .primaryAction) {
            Toggle(isOn: $settings.onlyApplications) { Label("Apps", systemImage: "macwindow.on.rectangle") }
                .help("Show only GUI applications (⌥⌘A)")
                .disabled(tab != .processes)
        }
        ToolbarItem(id: "mine", placement: .primaryAction) {
            Toggle(isOn: $settings.hideOtherUsers) { Label("Mine", systemImage: "person.crop.circle") }
                .help("Show only my processes (⌥⌘U)")
                .disabled(tab != .processes)
        }
        ToolbarItem(id: "treeList", placement: .primaryAction) {
            Toggle(isOn: $settings.treeView) {
                Label(settings.treeView ? "Tree" : "List", systemImage: settings.treeView ? "list.bullet.indent" : "list.bullet")
            }
            .help(settings.treeView ? "Showing hierarchy — click for a flat list (⌥⌘T)" : "Showing a flat list — click for the hierarchy (⌥⌘T)")
            .disabled(tab != .processes)
        }
        ToolbarItem(id: "filters", placement: .primaryAction) {
            FiltersMenu().disabled(tab != .processes)
        }
    }

    @ToolbarContentBuilder
    private var actionToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "refresh", placement: .primaryAction) {
            Button { store.refreshNow(); if tab == .services { ServiceStore.shared.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh now (⌘R)")
        }
        ToolbarItem(id: "pause", placement: .primaryAction) {
            Toggle(isOn: $store.paused) {
                Label(store.paused ? "Resume" : "Pause", systemImage: store.paused ? "play.fill" : "pause.fill")
            }
            .help(store.paused ? "Resume updates" : "Pause updates")
        }
        ToolbarItem(id: "sysinfo", placement: .primaryAction) {
            Button { SystemInfoWindow.open() } label: {
                Label("System Information", systemImage: "chart.xyaxis.line")
            }
            .help("System information (⌘I)")
        }
        ToolbarItem(id: "find", placement: .primaryAction) {
            Button { FindWindow.open() } label: {
                Label("Find Files", systemImage: "doc.text.magnifyingglass")
            }
            .help("Find open files or loaded libraries (⇧⌘F)")
        }
        ToolbarItem(id: "elevate", placement: .primaryAction) {
            ElevationButton(revision: elevationRevision)
        }
        ToolbarItem(id: "regex", placement: .primaryAction) {
            RegexToggle()
        }
        ToolbarItem(id: "settings", placement: .primaryAction) {
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }

    /// Optional items, available from Customize Toolbar.
    @ToolbarContentBuilder
    private var optionalToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "properties", placement: .primaryAction, showsByDefault: false) {
            Button { if let p = ProcessSelection.shared.items.first { PropertiesWindow.open(p) } } label: {
                Label("Properties", systemImage: "info.circle")
            }
            .help("Properties of the selected process (⌘↩)")
        }
        ToolbarItem(id: "terminate", placement: .primaryAction, showsByDefault: false) {
            Button { ProcessActions.terminate(ProcessSelection.shared.items) } label: {
                Label("Terminate", systemImage: "xmark.circle")
            }
            .help("Terminate the selected processes (⌘⌫)")
        }
        ToolbarItem(id: "kill", placement: .primaryAction, showsByDefault: false) {
            Button { ProcessActions.forceKill(ProcessSelection.shared.items) } label: {
                Label("Force Kill", systemImage: "bolt.circle")
            }
            .help("Force kill the selected processes (⌥⌘⌫)")
        }
        ToolbarItem(id: "inspect", placement: .primaryAction, showsByDefault: false) {
            Button { InspectorWindow.choose() } label: {
                Label("Inspect", systemImage: "doc.viewfinder")
            }
            .help("Inspect an executable (⌘O)")
        }
        ToolbarItem(id: "run", placement: .primaryAction, showsByDefault: false) {
            Button { RunWindow.open(asRoot: false) } label: {
                Label("Run", systemImage: "play.rectangle")
            }
            .help("Run a program (⌘N)")
        }
        ToolbarItem(id: "log", placement: .primaryAction, showsByDefault: false) {
            Button { EventLogWindow.open() } label: {
                Label("Event Log", systemImage: "list.bullet.rectangle")
            }
            .help("Event log (⌥⌘L)")
        }
    }

    @ToolbarContentBuilder
    private var moreOptionalToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "windows", placement: .primaryAction, showsByDefault: false) {
            Button { WindowFinder.open() } label: {
                Label("Find Window", systemImage: "macwindow.badge.plus")
            }
            .help("Find a process by its window")
        }
        ToolbarItem(id: "users", placement: .primaryAction, showsByDefault: false) {
            Button { UsersWindow.open() } label: {
                Label("Users", systemImage: "person.2")
            }
            .help("Logged-in users")
        }
        ToolbarItem(id: "hidden", placement: .primaryAction, showsByDefault: false) {
            Button { HiddenProcessesWindow.open() } label: {
                Label("Hidden Scan", systemImage: "eye.trianglebadge.exclamationmark")
            }
            .help("Scan for hidden processes")
        }
        ToolbarItem(id: "export", placement: .primaryAction, showsByDefault: false) {
            Button { Alerts.save(text: ProcessSelection.shared.table.exportText(), suggestedName: "Processes.txt") } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the process list (⌘S)")
        }
        ToolbarItem(id: "font", placement: .primaryAction, showsByDefault: false) {
            Toggle(isOn: $settings.processListMonospaced) {
                Label("Fixed Width", systemImage: "textformat.size")
            }
            .help("Fixed-width font in the process list")
        }
    }
}

/// Toolbar menu with the less common filters and the saved filters.
struct FiltersMenu: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Menu {
            Toggle("Hide Root & System Processes", isOn: $settings.hideSystemProcesses)
            Toggle("Hide Apple-Signed Processes", isOn: $settings.hideAppleProcesses)
            Toggle("Hide Zombie Processes", isOn: $settings.hideZombies)
            Divider()
            Toggle("Only Applications", isOn: $settings.onlyApplications)
            Toggle("Only My Processes", isOn: $settings.hideOtherUsers)
            Button("Reset Filters") {
                settings.resetProcessFilters()
                ProcessStore.shared.filter.text = ""
            }
            .disabled(!settings.hasProcessFilters && ProcessStore.shared.filter.text.isEmpty)
            Divider()
            Section("Saved Filters") {
                SavedFiltersMenuItems()
            }
        } label: {
            Label("Filters", systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Filters and saved filters")
    }

    private var active: Bool {
        settings.hideSystemProcesses || settings.hideAppleProcesses || settings.hideZombies || settings.activeSavedFilter != nil
    }
}

struct ElevationButton: View {
    var revision: Int

    var body: some View {
        let mode = Elevation.shared.mode
        Button {
            if mode == .standard {
                Task {
                    do {
                        try await Elevation.shared.startHelper()
                    } catch let e as PrivilegedError where e == .cancelled {
                    } catch {
                        Alerts.error("Unable to elevate", error.localizedDescription)
                    }
                }
            } else {
                Alerts.info(mode == .root ? "Running as root" : "Elevated",
                            mode == .root
                                ? "Process Informer is running with root privileges. All processes are visible and no authorization prompts will be shown."
                                : "A privileged helper is running for this session. Details for all processes are available and actions will not prompt again until you quit.")
            }
        } label: {
            Label(mode == .standard ? "Show Details for All Processes" : "Elevated",
                  systemImage: mode == .standard ? "lock.fill" : "lock.open.fill")
        }
        .help(mode == .standard ? "Authorize once to see details of all processes and perform privileged actions" : "Elevated: \(mode.rawValue)")
        .id(revision)
    }
}

struct StatusBarView: View {
    @ObservedObject private var store = ProcessStore.shared
    var elevationRevision: Int
    var searchError: String?
    var showFilterSummary = false

    var body: some View {
        let sys = store.system
        let vm = sys.last?.vm
        HStack(spacing: 16) {
            stat("CPU", String(format: "%.1f%%", sys.cpuUsage))
            if let vm {
                stat("Memory", "\(Fmt.bytes(vm.usedBytes)) / \(Fmt.bytes(vm.totalBytes)) (\(String(format: "%.0f%%", Double(vm.usedBytes) / Double(max(1, vm.totalBytes)) * 100)))")
                stat("Swap", Fmt.bytes(vm.swapUsed))
                stat("Pressure", vm.pressureDescription)
            }
            stat("Processes", "\(store.processCount)")
            stat("Threads", Fmt.count(store.totalThreads))
            stat("Disk", "↓\(Fmt.rate(sys.diskReadRate).ifEmpty("0")) ↑\(Fmt.rate(sys.diskWriteRate).ifEmpty("0"))")
            stat("Network", "↓\(Fmt.rate(sys.netInRate).ifEmpty("0")) ↑\(Fmt.rate(sys.netOutRate).ifEmpty("0"))")
            Spacer()
            if showFilterSummary, store.filter.isFiltering {
                if let saved = AppSettings.shared.activeSavedFilter {
                    Label(saved.name, systemImage: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.secondary)
                }
                Text("Showing \(Fmt.count(store.matchCount)) of \(Fmt.count(store.processCount)) processes")
                    .foregroundStyle(.secondary)
                Button("Clear Filters") {
                    AppSettings.shared.resetProcessFilters()
                    store.filter.text = ""
                }
                .controlSize(.small)
                .buttonStyle(.link)
            }
            if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if store.paused {
                Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
            }
            modeLabel
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var modeLabel: some View {
        _ = elevationRevision
        let mode = Elevation.shared.mode
        return Label(mode.rawValue, systemImage: mode == .standard ? "person" : "shield.lefthalf.filled")
            .foregroundStyle(mode == .standard ? Color.secondary : Color.orange)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title + ":").foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// Gives access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let w = view.window { configure(w) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Lets AppKit code (launch arguments, menus) open the SwiftUI Settings scene.
@MainActor
enum SettingsOpener {
    static var action: (() -> Void)?

    static func open(tab: SettingsTab? = nil) {
        if let tab {
            UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
        }
        action?()
    }
}

