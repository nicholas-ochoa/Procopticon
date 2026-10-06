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
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if tab == .processes {
            ToolbarItem(placement: .primaryAction) {
                ProcessFilterControls()
            }
        }
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $tab) {
                ForEach(MainTab.allCases) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleOnly)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.refreshNow(); if tab == .services { ServiceStore.shared.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh now")
            Toggle(isOn: $store.paused) {
                Label("Pause", systemImage: store.paused ? "play.fill" : "pause.fill")
            }
            .help(store.paused ? "Resume updates" : "Pause updates")
            Button { SystemInfoWindow.open() } label: {
                Label("System Information", systemImage: "chart.xyaxis.line")
            }
            .help("System information")
            Button { FindWindow.open() } label: {
                Label("Find Files or Libraries", systemImage: "doc.text.magnifyingglass")
            }
            .help("Find open files or loaded libraries")
            ElevationButton(revision: elevationRevision)
            RegexToggle()
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
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
}

/// Quick filter presets for the process list.
struct ProcessFilterControls: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ControlGroup {
            Toggle(isOn: $settings.onlyApplications) {
                Label("Apps", systemImage: "macwindow.on.rectangle")
            }
            .help("Show only GUI applications (⌥⌘A)")
            Toggle(isOn: $settings.hideOtherUsers) {
                Label("Mine", systemImage: "person.crop.circle")
            }
            .help("Show only my processes (⌥⌘U)")
            Toggle(isOn: $settings.treeView) {
                Label(settings.treeView ? "Tree" : "List", systemImage: settings.treeView ? "list.bullet.indent" : "list.bullet")
            }
            .help(settings.treeView ? "Showing hierarchy — click for a flat list (⌥⌘T)" : "Showing a flat list — click for the hierarchy (⌥⌘T)")
            Menu {
                Toggle("Hide Root & System Processes", isOn: $settings.hideSystemProcesses)
                Toggle("Hide Apple-Signed Processes", isOn: $settings.hideAppleProcesses)
                Toggle("Hide Zombie Processes", isOn: $settings.hideZombies)
                Divider()
                Toggle("Only Applications", isOn: $settings.onlyApplications)
                Toggle("Only My Processes", isOn: $settings.hideOtherUsers)
                Divider()
                Button("Reset Filters") { settings.resetProcessFilters() }
                    .disabled(!settings.hasProcessFilters)
            } label: {
                Label("Filters", systemImage: moreFiltersActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("More filters")
        }
        .toggleStyle(.button)
        .labelStyle(.titleAndIcon)
    }

    private var moreFiltersActive: Bool {
        settings.hideSystemProcesses || settings.hideAppleProcesses || settings.hideZombies
    }
}
