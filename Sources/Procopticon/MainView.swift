import AppKit
import Combine
import ProcopticonCore
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

    var help: String {
        switch self {
        case .processes: return "All running processes with CPU, memory and disk usage"
        case .services: return "launchd daemons, agents and login items, and their state"
        case .network: return "Open TCP and UDP connections and the processes that own them"
        case .disk: return "Processes currently reading from or writing to disk"
        }
    }
}

extension Notification.Name {
    static let showTab = Notification.Name("Procopticon.ShowTab")
    static let focusSearch = Notification.Name("Procopticon.FocusSearch")
}

/// Tab and search state of the main window.
///
/// Deliberately *not* observed by `MainView`: the toolbar builder lives in `MainView.body`, and
/// re-running it makes SwiftUI rebuild every toolbar item. Only the small views that display this
/// state observe it, so switching tabs or typing updates just those views.
final class MainWindowState: ObservableObject {
    static let shared = MainWindowState()

    @Published var tab: MainTab {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "mainTab")
            if oldValue != tab, !otherSearch.isEmpty {
                otherSearch = ""
            }
        }
    }
    @Published var processSearch = "" {
        didSet {
            if ProcessStore.shared.filter.text != processSearch {
                ProcessStore.shared.filter.text = processSearch
            }
        }
    }
    @Published var otherSearch = ""
    @Published private(set) var elevationRevision = 0
    private var observers: [NSObjectProtocol] = []
    private var cancellable: AnyCancellable?

    private init() {
        tab = MainTab(rawValue: UserDefaults.standard.string(forKey: "mainTab") ?? "") ?? .processes
        observers.append(NotificationCenter.default.addObserver(forName: .showTab, object: nil, queue: .main) { [weak self] n in
            if let t = n.object as? MainTab, self?.tab != t { self?.tab = t }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Elevation.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.elevationRevision &+= 1
        })
        // Mirror filter text set elsewhere (saved filters, "Go to process") into the search field.
        cancellable = ProcessStore.shared.$revision.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            let text = ProcessStore.shared.filter.text
            if text != self.processSearch {
                self.processSearch = text
            }
        }
    }

    var searchBinding: Binding<String> {
        Binding(
            get: { self.tab == .processes ? self.processSearch : self.otherSearch },
            set: { if self.tab == .processes { self.processSearch = $0 } else { self.otherSearch = $0 } })
    }
}

struct MainView: View {
    var body: some View {
        MainContentView()
            .navigationTitle("Procopticon")
            .toolbar(id: "main") { toolbar }
            .toolbar(removing: .title)
            .background(WindowAccessor { window in
                window.identifier = NSUserInterfaceItemIdentifier("main")
                window.level = AppSettings.shared.alwaysOnTop ? .floating : .normal
                window.setFrameAutosaveName("MainWindow")
            })
    }

    /// Customizable toolbar (View ▸ Customize Toolbar…).
    ///
    /// The title and tab picker stay fixed on the left. By default a flexible space follows them so the
    /// buttons sit on the right, arranged in logical groups separated by fixed spaces. Every group and
    /// every individual button is also offered in the palette. All items are self-contained views, so
    /// this builder never needs to re-run after the window appears.
    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        fixedToolbarItems
        ToolbarSpacer(.flexible, placement: .primaryAction)
        defaultGroupItems
        searchToolbarItem
        optionalGroupItems
        individualFilterItems
        individualActionItems
        individualProcessItems
        individualToolItems
    }

    @ToolbarContentBuilder
    private var fixedToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "title", placement: .navigation) { WindowTitleView() }
            // Plain title text, not a glass toolbar "bubble".
            .sharedBackgroundVisibility(.hidden)
            .customizationBehavior(.disabled)
        ToolbarItem(id: "tabs", placement: .navigation) { TabPickerView() }
            .customizationBehavior(.disabled)
    }

    @ToolbarContentBuilder
    private var searchToolbarItem: some CustomizableToolbarContent {
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "search", placement: .primaryAction) { MainSearchField() }
    }

    // MARK: Groups

    /// Groups shown by default (in this order, right-aligned).
    @ToolbarContentBuilder
    private var defaultGroupItems: some CustomizableToolbarContent {
        ToolbarItem(id: "group.filters", placement: .primaryAction) {
            ToolbarGroup("Quick Filters", "line.3.horizontal.decrease", processesOnly: true) {
                AppsToggle()
                MineToggle()
                TreeToggle()
                FiltersMenu()
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "group.updates", placement: .primaryAction) {
            ToolbarGroup("Updates", "arrow.clockwise") {
                RefreshButton()
                PauseToggle()
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "group.tools", placement: .primaryAction) {
            ToolbarGroup("Tools", "wrench.and.screwdriver") {
                ToolbarActionButton(.sysinfo)
                ToolbarActionButton(.history)
                ToolbarActionButton(.find)
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "group.privileges", placement: .primaryAction) {
            ToolbarGroup("Privileges & Settings", "lock.shield") {
                ElevationButton()
                ToolbarActionButton(.settings)
            }
        }
    }

    /// Additional groups available from Customize Toolbar.
    @ToolbarContentBuilder
    private var optionalGroupItems: some CustomizableToolbarContent {
        ToolbarItem(id: "group.process", placement: .primaryAction, showsByDefault: false) {
            ToolbarGroup("Process Actions", "app.badge") {
                ToolbarActionButton(.properties)
                ToolbarActionButton(.terminate)
                ToolbarActionButton(.kill)
            }
        }
        ToolbarItem(id: "group.windows", placement: .primaryAction, showsByDefault: false) {
            ToolbarGroup("Inspection Windows", "rectangle.stack") {
                ToolbarActionButton(.log)
                ToolbarActionButton(.crashes)
                ToolbarActionButton(.startup)
                ToolbarActionButton(.windows)
                ToolbarActionButton(.users)
                ToolbarActionButton(.hidden)
            }
        }
        ToolbarItem(id: "group.files", placement: .primaryAction, showsByDefault: false) {
            ToolbarGroup("Files & Programs", "doc.on.doc") {
                ToolbarActionButton(.inspect)
                ToolbarActionButton(.run)
                ToolbarActionButton(.export)
            }
        }
    }

    // MARK: Individual items (palette only)

    @ToolbarContentBuilder
    private var individualFilterItems: some CustomizableToolbarContent {
        ToolbarItem(id: "apps", placement: .primaryAction, showsByDefault: false) { ProcessesOnly { AppsToggle() } }
        ToolbarItem(id: "mine", placement: .primaryAction, showsByDefault: false) { ProcessesOnly { MineToggle() } }
        ToolbarItem(id: "treeList", placement: .primaryAction, showsByDefault: false) { ProcessesOnly { TreeToggle() } }
        ToolbarItem(id: "filters", placement: .primaryAction, showsByDefault: false) { ProcessesOnly { FiltersMenu() } }
    }

    @ToolbarContentBuilder
    private var individualActionItems: some CustomizableToolbarContent {
        ToolbarItem(id: "refresh", placement: .primaryAction, showsByDefault: false) { RefreshButton() }
        ToolbarItem(id: "pause", placement: .primaryAction, showsByDefault: false) { PauseToggle() }
        ToolbarItem(id: "elevate", placement: .primaryAction, showsByDefault: false) { ElevationButton() }
        ToolbarItem(id: "settings", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.settings) }
    }

    @ToolbarContentBuilder
    private var individualProcessItems: some CustomizableToolbarContent {
        ToolbarItem(id: "properties", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.properties) }
        ToolbarItem(id: "terminate", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.terminate) }
        ToolbarItem(id: "kill", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.kill) }
        ToolbarItem(id: "export", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.export) }
        ToolbarItem(id: "inspect", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.inspect) }
        ToolbarItem(id: "run", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.run) }
    }

    @ToolbarContentBuilder
    private var individualToolItems: some CustomizableToolbarContent {
        ToolbarItem(id: "sysinfo", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.sysinfo) }
        ToolbarItem(id: "history", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.history) }
        ToolbarItem(id: "find", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.find) }
        ToolbarItem(id: "log", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.log) }
        ToolbarItem(id: "crashes", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.crashes) }
        ToolbarItem(id: "startup", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.startup) }
        ToolbarItem(id: "windows", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.windows) }
        ToolbarItem(id: "users", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.users) }
        ToolbarItem(id: "hidden", placement: .primaryAction, showsByDefault: false) { ToolbarActionButton(.hidden) }
    }
}

/// Window content: the four tabs and the status bar.
struct MainContentView: View {
    @ObservedObject private var state = MainWindowState.shared
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(SummarySection.storageKey) private var summarySection = ""

    var body: some View {
        VStack(spacing: 0) {
            // All tabs stay alive; inactive ones are hidden and pause their updates, so switching
            // tabs is instant instead of rebuilding a large table on the main thread.
            ZStack {
                ProcessTreeView(active: state.tab == .processes)
                tab(.services) { ServicesView(search: $state.otherSearch, active: $0) }
                tab(.network) { NetworkView(search: $state.otherSearch, active: $0) }
                tab(.disk) { DiskView(search: $state.otherSearch, active: $0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // No cross-fade: animating four large tables forces repeated layout and commits.
            .transaction { $0.animation = nil }
            if settings.showStatusBar {
                if let section = SummarySection(rawValue: summarySection) {
                    Divider()
                    StatusSummaryPanel(section: section)
                }
                Divider()
                MainStatusBar()
            }
        }
    }

    private func tab<Content: View>(_ t: MainTab, @ViewBuilder content: (Bool) -> Content) -> some View {
        let active = state.tab == t
        return content(active)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
    }
}

struct MainStatusBar: View {
    @ObservedObject private var state = MainWindowState.shared
    @ObservedObject private var store = ProcessStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        StatusBarView(elevationRevision: state.elevationRevision,
                      searchError: state.tab == .processes ? store.filterError : settings.matcher(state.otherSearch).error,
                      showFilterSummary: state.tab == .processes)
    }
}

// MARK: - Toolbar item views

struct WindowTitleView: View {
    @ObservedObject private var store = ProcessStore.shared

    var body: some View {
        let subtitle = store.processCount == 1 ? "1 process" : "\(Fmt.count(store.processCount)) processes"
        VStack(alignment: .leading, spacing: 0) {
            Text("Procopticon").font(.headline)
            Text(subtitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 6)
    }
}

struct TabPickerView: View {
    @ObservedObject private var state = MainWindowState.shared

    var body: some View {
        Picker("View", selection: $state.tab) {
            ForEach(MainTab.allCases) { t in
                Label(t.rawValue, systemImage: t.symbol).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleOnly)
        .help("Switch between processes, launchd services, network connections and disk activity")
        .background(SegmentToolTips(tips: MainTab.allCases.map(\.help)))
    }
}

struct MainSearchField: View {
    @ObservedObject private var state = MainWindowState.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        RegexSearchFieldView(
            text: state.searchBinding,
            regex: $settings.searchUsesRegex,
            javaScript: state.tab == .processes ? $settings.searchUsesJavaScript : nil,
            prompt: state.tab == .processes ? "Search processes" : "Search \(state.tab.rawValue.lowercased())",
            toolTip: state.tab == .processes
                ? "Filter the list by name, PID, path, command line or user. Click .* for a regular expression, or {} for a JavaScript expression such as cpu > 10 && user == \"root\" (⌘F)"
                : "Filter the list. Click .* or write /pattern/ for a regular expression (⌘F)",
            focusOnFind: true)
            .frame(minWidth: 180, idealWidth: 260, maxWidth: 360)
    }
}

/// A named cluster of toolbar controls.
struct ToolbarGroup<Content: View>: View {
    let title: String
    let symbol: String
    var processesOnly = false
    @ViewBuilder var content: Content

    init(_ title: String, _ symbol: String, processesOnly: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.processesOnly = processesOnly
        self.content = content()
    }

    var body: some View {
        let group = ControlGroup {
            content
        } label: {
            Label(title, systemImage: symbol)
        }
        .controlGroupStyle(ToolbarClusterStyle())
        if processesOnly {
            ProcessesOnly { group }
        } else {
            group
        }
    }
}

/// Disables its content unless the Processes tab is showing.
struct ProcessesOnly<Content: View>: View {
    @ObservedObject private var state = MainWindowState.shared
    @ViewBuilder var content: Content

    var body: some View {
        content.disabled(state.tab != .processes)
    }
}

struct AppsToggle: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(isOn: $settings.onlyApplications) { Label("Apps", systemImage: "macwindow.on.rectangle") }
            .help("Show only applications with a user interface and the processes they started (⌥⌘A)")
    }
}

struct MineToggle: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(isOn: $settings.hideOtherUsers) { Label("Mine", systemImage: "person.crop.circle") }
            .help("Show only processes running as you, hiding other users and system accounts (⌥⌘U)")
    }
}

struct TreeToggle: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(isOn: $settings.treeView) {
            Label(settings.treeView ? "Tree" : "List", systemImage: settings.treeView ? "list.bullet.indent" : "list.bullet")
        }
        .help(settings.treeView
            ? "Processes are shown as a parent/child tree. Click to show a flat list (⌥⌘T)"
            : "Processes are shown as a flat list. Click to show the parent/child tree (⌥⌘T)")
    }
}

struct RefreshButton: View {
    var body: some View {
        Button {
            ProcessStore.shared.refreshNow()
            if MainWindowState.shared.tab == .services { ServiceStore.shared.refresh() }
            if MainWindowState.shared.tab == .network { NetworkStore.shared.refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Update all data now instead of waiting for the next refresh (⌘R)")
    }
}

struct PauseToggle: View {
    @ObservedObject private var pause = PauseState.shared

    var body: some View {
        Toggle(isOn: Binding(get: { pause.paused }, set: { ProcessStore.shared.paused = $0 })) {
            Label(pause.paused ? "Resume" : "Pause", systemImage: pause.paused ? "play.fill" : "pause.fill")
        }
        .help(pause.paused
            ? "Updates are paused. Click to resume live updates (⌥⌘P)"
            : "Pause live updates so the lists stop changing while you look (⌥⌘P)")
    }
}

/// Plain action buttons used in groups and as individual palette items.
struct ToolbarActionButton: View {
    enum Action {
        case sysinfo, history, find, settings, properties, terminate, kill, inspect, run, log, crashes, startup, windows, users, hidden, export
    }

    let action: Action

    init(_ action: Action) {
        self.action = action
    }

    var body: some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
        }
        .help(help)
    }

    private func perform() {
        switch action {
        case .sysinfo: SystemInfoWindow.open()
        case .history: ResourceHistoryWindow.open()
        case .find: FindWindow.open()
        case .settings: SettingsWindow.open()
        case .properties: if let p = ProcessSelection.shared.items.first { PropertiesWindow.open(p) }
        case .terminate: ProcessActions.terminate(ProcessSelection.shared.items)
        case .kill: ProcessActions.forceKill(ProcessSelection.shared.items)
        case .inspect: InspectorWindow.choose()
        case .run: RunWindow.open(asRoot: false)
        case .log: EventLogWindow.open()
        case .crashes: CrashReportsWindow.open()
        case .startup: StartupItemsWindow.open()
        case .windows: WindowFinder.open()
        case .users: UsersWindow.open()
        case .hidden: HiddenProcessesWindow.open()
        case .export: TableExport.saveProcessList()
        }
    }

    private var title: String {
        switch action {
        case .sysinfo: return "System Information"
        case .history: return "Resource History"
        case .find: return "Find Files"
        case .settings: return "Settings"
        case .properties: return "Properties"
        case .terminate: return "Terminate"
        case .kill: return "Force Kill"
        case .inspect: return "Inspect"
        case .run: return "Run"
        case .log: return "Event Log"
        case .crashes: return "Crash Reports"
        case .startup: return "Startup Items"
        case .windows: return "Find Window"
        case .users: return "Users"
        case .hidden: return "Hidden Scan"
        case .export: return "Export"
        }
    }

    private var symbol: String {
        switch action {
        case .sysinfo: return "chart.xyaxis.line"
        case .history: return "chart.bar.xaxis"
        case .find: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        case .properties: return "info.circle"
        case .terminate: return "xmark.circle"
        case .kill: return "bolt.circle"
        case .inspect: return "doc.viewfinder"
        case .run: return "play.rectangle"
        case .log: return "list.bullet.rectangle"
        case .crashes: return "exclamationmark.triangle"
        case .startup: return "power.circle"
        case .windows: return "macwindow.badge.plus"
        case .users: return "person.2"
        case .hidden: return "eye.trianglebadge.exclamationmark"
        case .export: return "square.and.arrow.up"
        }
    }

    private var help: String {
        switch action {
        case .sysinfo: return "Open System Information: CPU, memory, disk, network, GPU and power graphs (⌘I)"
        case .history: return "Open a floating window of CPU core, GPU and memory history graphs (⌥⌘G)"
        case .find: return "Find which processes have a file, socket or library open (⇧⌘F)"
        case .settings: return "Open Settings: updates, filters, highlighting and privileges (⌘,)"
        case .properties: return "Show details of the selected process: threads, files, memory, security and more (⌘↩)"
        case .terminate: return "Ask the selected processes to quit (SIGTERM) (⌘⌫)"
        case .kill: return "Kill the selected processes immediately (SIGKILL); unsaved work is lost (⌥⌘⌫)"
        case .inspect: return "Inspect an app or binary: architectures, libraries, symbols, code signature (⌘O)"
        case .run: return "Start a program, optionally as root (⌘N)"
        case .log: return "Show the log of processes and services starting and stopping (⌥⌘L)"
        case .crashes: return "List crash, hang and resource reports, grouped by process"
        case .startup: return "List login items, background items, extensions, cron jobs and other things that start code"
        case .windows: return "List on-screen windows to find the process that owns one"
        case .users: return "Show logged-in users and their processes, CPU and memory"
        case .hidden: return "Scan every PID to detect processes hidden from the process list"
        case .export: return "Save the visible process list as JSON or CSV (⌘S)"
        }
    }
}

/// Toolbar menu with the less common filters and the saved filters. An AppKit menu (see
/// `NativeMenuButton`): the window updates every refresh, which re-applied a SwiftUI menu's items
/// while it was open.
struct FiltersMenu: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        NativeMenuButton(menu: Self.makeMenu) {
            Label {
                Text("Filters")
            } icon: {
                // The chevron marks it as a menu, as SwiftUI's toolbar menus show.
                HStack(spacing: 1) {
                    Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
        }
        .help("More filters (hide system, Apple-signed or zombie processes, show hung applications) and your saved filters")
    }

    private var active: Bool {
        settings.hideSystemProcesses || settings.hideAppleProcesses || settings.hideZombies || settings.onlyNotResponding
            || settings.activeSavedFilter != nil
    }

    @MainActor
    static func makeMenu() -> NSMenu {
        let settings = AppSettings.shared
        let menu = NSMenu()
        func toggle(_ title: String, _ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) {
            menu.add(title, state: settings[keyPath: keyPath] ? .on : .off) { settings[keyPath: keyPath].toggle() }
        }
        toggle("Hide Root & System Processes", \.hideSystemProcesses)
        toggle("Hide Apple-Signed Processes", \.hideAppleProcesses)
        toggle("Hide Zombie Processes", \.hideZombies)
        menu.addItem(.separator())
        toggle("Only Applications", \.onlyApplications)
        toggle("Only My Processes", \.hideOtherUsers)
        toggle("Only Applications Not Responding", \.onlyNotResponding)
        menu.add("Reset Filters", enabled: settings.hasProcessFilters || !ProcessStore.shared.filter.text.isEmpty) {
            settings.resetProcessFilters()
            ProcessStore.shared.filter.text = ""
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Saved Filters"))
        let active = settings.activeSavedFilter?.id
        for filter in settings.savedFilters {
            menu.add(filter.name, state: filter.id == active ? .on : .off) { settings.applySavedFilter(filter) }
        }
        if !settings.savedFilters.isEmpty {
            menu.addItem(.separator())
        }
        menu.add("Save Current Filter…") { settings.saveCurrentFilterInteractively() }
        menu.add("Manage Saved Filters…") { SettingsWindow.open(tab: .filters) }
        return menu
    }
}

struct ElevationButton: View {
    @ObservedObject private var state = MainWindowState.shared

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
                                ? "Procopticon is running with root privileges. All processes are visible and no authorization prompts will be shown."
                                : "A privileged helper is running for this session. Details for all processes are available and actions will not prompt again until you quit.")
            }
        } label: {
            Label(mode == .standard ? "Show Details for All Processes" : "Elevated",
                  systemImage: mode == .standard ? "lock.fill" : "lock.open.fill")
        }
        .help(mode == .standard ? "Authorize once (administrator password) to see every process in full and act on other users' processes" : "Running with administrator rights (\(mode.rawValue)). Click for details")
        .id(state.elevationRevision)
    }
}

struct StatusBarView: View {
    @ObservedObject private var store = ProcessStore.shared
    @AppStorage(SummarySection.storageKey) private var summarySection = ""
    var elevationRevision: Int
    var searchError: String?
    var showFilterSummary = false

    var body: some View {
        let sys = store.system
        let vm = sys.last?.vm
        HStack(spacing: 6) {
            sectionButton(.cpu) {
                stat("CPU", String(format: "%.1f%%", sys.cpuUsage))
                stat("Processes", "\(store.processCount)")
                stat("Threads", Fmt.count(store.totalThreads))
            }
            if let vm {
                sectionButton(.memory) {
                    stat("Memory", "\(Fmt.bytes(vm.usedBytes)) / \(Fmt.bytes(vm.totalBytes)) (\(String(format: "%.0f%%", Double(vm.usedBytes) / Double(max(1, vm.totalBytes)) * 100)))")
                    stat("Swap", Fmt.bytes(vm.swapUsed))
                    stat("Pressure", vm.pressureDescription)
                }
            }
            sectionButton(.disk) {
                stat("Disk", "↓\(Fmt.rate(sys.diskReadRate).ifEmpty("0")) ↑\(Fmt.rate(sys.diskWriteRate).ifEmpty("0"))")
            }
            sectionButton(.network) {
                stat("Network", "↓\(Fmt.rate(sys.netInRate).ifEmpty("0")) ↑\(Fmt.rate(sys.netOutRate).ifEmpty("0"))")
            }
            if !sys.gpu.ordered.isEmpty {
                sectionButton(.gpu) {
                    stat("GPU", String(format: "%.0f%%", sys.gpu.last))
                }
            }
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
                .help("Clear the search and turn off every filter, showing all processes")
            }
            if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .help(searchError)
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
        return Label(mode == .helper ? "Elevated" : mode.rawValue, systemImage: mode == .standard ? "person" : "shield.lefthalf.filled")
            .foregroundStyle(mode == .standard ? Color.secondary : Color.orange)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title + ":").foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// A group of stats that opens (or closes) its section of the summary panel.
    private func sectionButton<Content: View>(_ section: SummarySection, @ViewBuilder content: () -> Content) -> some View {
        let open = summarySection == section.rawValue
        return Button {
            summarySection = open ? "" : section.rawValue
        } label: {
            HStack(spacing: 14) { content() }
        }
        .buttonStyle(StatusSectionButtonStyle(isOpen: open))
        .help(open ? "Hide the \(section.rawValue) details" : "Show \(section.rawValue) details above the status bar")
    }
}

/// Status bar stats that open a section of the summary panel: a hover highlight, and a tinted
/// capsule while their section is open.
private struct StatusSectionButtonStyle: ButtonStyle {
    var isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        StatusSectionCell(label: configuration.label, isPressed: configuration.isPressed, isOpen: isOpen)
    }
}

private struct StatusSectionCell<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isOpen: Bool
    @State private var hovering = false

    var body: some View {
        label
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(isOpen ? AnyShapeStyle(.tint.opacity(0.22))
                               : AnyShapeStyle(.primary.opacity(isPressed ? 0.14 : hovering ? 0.07 : 0)))
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
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

/// Lays a toolbar group's controls out side by side so the toolbar draws them as one cluster,
/// while the group's label still names it in the Customize Toolbar palette.
struct ToolbarClusterStyle: ControlGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            // Zero-size copy of the group's label: the toolbar palette names an item after the first
            // label it contains, so this makes the palette show "Quick Filters" rather than "Apps".
            configuration.label
                .labelStyle(.titleOnly)
                .frame(width: 0, height: 0)
                .clipped()
                .accessibilityHidden(true)
            configuration.content
                .labelStyle(.iconOnly)
                .buttonStyle(ToolbarClusterButtonStyle())
                .toggleStyle(ToolbarClusterToggleStyle())
        }
        .padding(.horizontal, 4)
    }
}

/// Buttons inside a toolbar group. The toolbar only draws its hover highlight for items it lays out
/// itself, so this draws the same thing: a capsule behind the icon when the pointer is over it. The
/// whole 32 × 36 pt cell is the hit area, not just the glyph.
struct ToolbarClusterButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarClusterCell(label: configuration.label, isPressed: configuration.isPressed, isOn: isOn)
    }
}

/// Toggles inside a toolbar group: a cluster button whose icon takes the accent color while on.
struct ToolbarClusterToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(ToolbarClusterButtonStyle(isOn: configuration.isOn))
            .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : .isToggle)
    }
}

private struct ToolbarClusterCell<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let highlight = isEnabled ? (isPressed ? 0.16 : hovering ? 0.09 : 0) : 0
        label
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: 32, height: 36)
            .background {
                // Same size as the native toolbar hover: 28 pt tall, inset within the toolbar capsule.
                Capsule()
                    .fill(.primary.opacity(highlight))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: highlight)
    }
}

/// Native search field with a ".*" regular-expression toggle at its trailing edge, used for the
/// toolbar search and the filter fields above lists.
struct RegexSearchFieldView: NSViewRepresentable {
    @Binding var text: String
    @Binding var regex: Bool
    /// When given, a {} toggle for JavaScript expressions (the process search).
    var javaScript: Binding<Bool>?
    var prompt: String
    var toolTip: String?
    /// The search is invalid (e.g. a malformed regular expression); the toggle turns red.
    var isInvalid = false
    /// Find (⌘F) focuses this field.
    var focusOnFind = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RegexSearchField {
        let field = RegexSearchField()
        field.delegate = context.coordinator
        field.regexButton.target = context.coordinator
        field.regexButton.action = #selector(Coordinator.toggleRegex(_:))
        field.javaScriptButton.target = context.coordinator
        field.javaScriptButton.action = #selector(Coordinator.toggleJavaScript(_:))
        field.isRegex = regex
        field.showsJavaScript = javaScript != nil
        field.isJavaScript = javaScript?.wrappedValue ?? false
        field.isInvalid = isInvalid
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.placeholderString = prompt
        field.stringValue = text
        field.toolTip = toolTip
        context.coordinator.field = field
        context.coordinator.startCompleting()
        if focusOnFind {
            context.coordinator.focusObserver = NotificationCenter.default.addObserver(
                forName: .focusSearch, object: nil, queue: .main) { [weak field] _ in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ field: RegexSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.isRegex != regex {
            field.isRegex = regex
        }
        if field.showsJavaScript != (javaScript != nil) {
            field.showsJavaScript = javaScript != nil
        }
        if field.isJavaScript != (javaScript?.wrappedValue ?? false) {
            field.isJavaScript = javaScript?.wrappedValue ?? false
            context.coordinator.completer.hide()
        }
        if field.isInvalid != isInvalid {
            field.isInvalid = isInvalid
        }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
        }
        if field.toolTip != toolTip {
            field.toolTip = toolTip
        }
    }

    static func dismantleNSView(_ field: RegexSearchField, coordinator: Coordinator) {
        coordinator.stopCompleting()
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: RegexSearchFieldView
        var focusObserver: NSObjectProtocol?
        weak var field: RegexSearchField?
        /// Completions for a JavaScript search, in the field editor while the field edits.
        private(set) lazy var completer = ExpressionCompleter(
            textView: { [weak self] in self?.field?.currentEditor() as? NSTextView },
            isEnabled: { [weak self] in self?.parent.javaScript?.wrappedValue == true })
        private var keyMonitor: Any?
        private var selectionObserver: NSObjectProtocol?

        init(_ parent: RegexSearchFieldView) {
            self.parent = parent
        }

        deinit {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        /// Watches for ⌃Space and caret moves while the field edits. The field editor is the
        /// window's, so this goes through a key monitor and notifications rather than a subclass.
        func startCompleting() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = ExpressionCompleter.isRequest(event) && MainActor.assumeIsolated {
                    guard let self, let field = self.field, event.window === field.window, field.currentEditor() != nil else {
                        return false
                    }
                    return self.completer.request()
                }
                return handled ? nil : event
            }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    if let self, let editor = n.object as? NSTextView, editor === self.field?.currentEditor() {
                        self.completer.selectionDidChange()
                    }
                }
            }
        }

        func stopCompleting() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            keyMonitor = nil
            selectionObserver = nil
            completer.hide()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
            completer.textDidChange()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            completer.hide()
        }

        @objc func toggleRegex(_ sender: NSButton) {
            parent.regex = sender.state == .on
        }

        @objc func toggleJavaScript(_ sender: NSButton) {
            parent.javaScript?.wrappedValue = sender.state == .on
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // The completion list's keys come first; with no list, Esc still clears the search.
            if completer.handle(selector, escapeRequests: false) {
                return true
            }
            // Escape clears the search, like the standard toolbar search field.
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                (control as? NSSearchField)?.stringValue = ""
                parent.text = ""
                return true
            }
            return false
        }
    }
}

/// Search field with a ".*" toggle (and optionally a "{}" one for JavaScript) inside its trailing
/// edge. The cell narrows the text area and moves the clear button left so they don't overlap.
final class RegexSearchField: NSSearchField {
    let regexButton = NSButton(title: ".*", target: nil, action: nil)
    let javaScriptButton = NSButton(title: "{}", target: nil, action: nil)

    override class var cellClass: AnyClass? {
        get { RegexSearchFieldCell.self }
        set {}
    }

    var isRegex = false {
        didSet { updateButtons() }
    }

    var isJavaScript = false {
        didSet { updateButtons() }
    }

    var showsJavaScript = false {
        didSet {
            javaScriptButton.isHidden = !showsJavaScript
            updateButtons()
            needsLayout = true
            needsDisplay = true
        }
    }

    var isInvalid = false {
        didSet { updateButtons() }
    }

    /// The toggles inside the trailing edge.
    var accessoryCount: Int { showsJavaScript ? 2 : 1 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [regexButton, javaScriptButton] {
            button.setButtonType(.pushOnPushOff)
            button.isBordered = false
            button.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            addSubview(button)
        }
        regexButton.setAccessibilityLabel("Regular expression")
        javaScriptButton.setAccessibilityLabel("JavaScript expression")
        javaScriptButton.isHidden = true
        updateButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // Search text is matched literally: no curly quotes or dashes in `user == "root"`.
        if became, let editor = currentEditor() as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
        return became
    }

    override func layout() {
        super.layout()
        let width = RegexSearchFieldCell.accessoryWidth
        regexButton.frame = NSRect(x: bounds.maxX - width - 6, y: bounds.minY, width: width, height: bounds.height)
        javaScriptButton.frame = regexButton.frame.offsetBy(dx: -width, dy: 0)
    }

    private func updateButtons() {
        regexButton.state = isRegex ? .on : .off
        regexButton.contentTintColor = isInvalid && isRegex ? .systemRed : isRegex ? .controlAccentColor : .secondaryLabelColor
        regexButton.toolTip = isRegex
            ? "Search text is a regular expression. Click for plain text matching (⌥⌘R)"
            : "Treat search text as a regular expression (⌥⌘R)"
        let javaScript = showsJavaScript && isJavaScript
        javaScriptButton.state = javaScript ? .on : .off
        javaScriptButton.contentTintColor = isInvalid && javaScript ? .systemRed : javaScript ? .controlAccentColor : .secondaryLabelColor
        javaScriptButton.toolTip = javaScript
            ? "Search text is a JavaScript expression over each process's values. Click for plain text matching (⌥⌘J)"
            : "Search with a JavaScript expression, such as cpu > 10 && user == \"root\" (⌥⌘J)"
        // Patterns and code read better in a fixed-width font.
        let size = self.font?.pointSize ?? NSFont.systemFontSize
        let font: NSFont = isRegex || javaScript
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        if self.font != font {
            self.font = font
            (currentEditor() as? NSTextView)?.font = font
        }
    }
}

final class RegexSearchFieldCell: NSSearchFieldCell {
    static let accessoryWidth: CGFloat = 24

    private var accessoriesWidth: CGFloat {
        Self.accessoryWidth * CGFloat((controlView as? RegexSearchField)?.accessoryCount ?? 1)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchTextRect(forBounds: rect)
        r.size.width -= accessoriesWidth
        return r
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.cancelButtonRect(forBounds: rect)
        r.origin.x -= accessoriesWidth
        return r
    }

    // The field's accessibility element is this cell, which lists only the search and clear buttons;
    // add the toggle so VoiceOver can reach it.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let field = controlView as? RegexSearchField {
            for button in field.showsJavaScript ? [field.javaScriptButton, field.regexButton] : [field.regexButton] {
                if let toggle = NSAccessibility.unignoredDescendant(of: button) {
                    children.append(toggle)
                }
            }
        }
        return children
    }
}

/// SwiftUI doesn't forward per-segment help to the native segmented control, so this finds the
/// `NSSegmentedControl` next to it and sets a tooltip for each segment.
struct SegmentToolTips: NSViewRepresentable {
    let tips: [String]

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView) }
    }

    private func apply(from view: NSView) {
        var container = view.superview
        for _ in 0..<6 {
            guard let c = container else { return }
            if let control = find(in: c) {
                for (i, tip) in tips.enumerated() where i < control.segmentCount {
                    control.setToolTip(tip, forSegment: i)
                }
                return
            }
            container = c.superview
        }
    }

    private func find(in view: NSView) -> NSSegmentedControl? {
        if let s = view as? NSSegmentedControl, s.segmentCount == tips.count {
            return s
        }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }
}
