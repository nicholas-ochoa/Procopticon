import AppKit
import Combine
import ProcopticonCore
import SwiftUI

@main
struct ProcopticonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        Window("Procopticon", id: "main") {
            MainView()
                .environmentObject(settings)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands() }

        MenuBarExtra(isInserted: Binding(
            get: { settings.showMenuBarExtra },
            set: { if settings.showMenuBarExtra != $0 { settings.showMenuBarExtra = $0 } })) {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        IsolatedScanner.executablePath = Elevation.helperURL.path
        ProcessStore.shared.applicationPids = ApplicationPids.current
        ProcessStore.shared.applicationResponsiveness = ApplicationResponsiveness.current
        // Mach ports are only counted while their column is showing; see OutlineTable's visibility keys.
        ProcessStore.shared.wantsPortCounts = {
            UserDefaults.standard.stringArray(forKey: "ProcessTree.shownColumns")?.contains("ports") == true
        }
        AppSettings.shared.apply()
        AppSettings.shared.applyAppearance()
        AppSettings.shared.applyAccentColor()
        ProcessStore.shared.start()
        AlertMonitor.shared.start()
        SensorMonitor.shared.start()
        // Prefetch launchd jobs in the background so the Services tab opens instantly.
        ServiceStore.shared.refresh()
        if AppSettings.shared.elevateAtLaunch, Elevation.shared.mode == .standard {
            Task { @MainActor in
                try? await Elevation.shared.startHelper()
            }
        }
        ResourceHistoryWindow.restore()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { LaunchArguments.apply() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ResourceHistoryWindow.saveState()
        Elevation.shared.stopLocalStreams()
        Elevation.shared.stopHelper()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.shared.showMenuBarExtra && !ResourceHistoryWindow.isOpen
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindow.open() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) { FileMenuItems() }
        CommandGroup(after: .toolbar) {
            ViewMenuUpdateItems()
            Divider()
            ViewMenuFilterItems()
            Divider()
            ViewMenuWindowItems()
        }
        ToolbarCommands()
        CommandGroup(after: .toolbar) {
            Menu("Saved Filters") { SavedFiltersMenuItems(shortcuts: true) }
        }
        CommandMenu("Process") { ProcessMenuItems() }
        CommandMenu("Tools") { ToolsMenuItems() }
    }
}

private func elevateFromMenu() {
    Task { @MainActor in
        do { try await Elevation.shared.startHelper() } catch let e as PrivilegedError where e == .cancelled {
        } catch { Alerts.error("Unable to elevate", error.localizedDescription) }
    }
}

@MainActor
private func relaunchAsRootFromMenu() {
    do {
        try Elevation.relaunchAsRoot()
        NSApp.terminate(nil)
    } catch let e as PrivilegedError where e == .cancelled {
    } catch {
        Alerts.error("Unable to relaunch", error.localizedDescription)
    }
}

struct FileMenuItems: View {
    var body: some View {
        Button("Run Program…") { RunWindow.open(asRoot: false) }
            .keyboardShortcut("n")
        Button("Run Program as Root…") { RunWindow.open(asRoot: true) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Divider()
        Button("Show Details for All Processes") { elevateFromMenu() }
            .disabled(Elevation.shared.mode != .standard)
        Button("Relaunch as Root…") { relaunchAsRootFromMenu() }
            .disabled(Elevation.shared.mode == .root)
        Divider()
        Button("Export Process List…") { TableExport.saveProcessList() }
        .keyboardShortcut("s")
        Button("Inspect Executable…") { InspectorWindow.choose() }
            .keyboardShortcut("o")
    }
}

struct ViewMenuUpdateItems: View {
    @ObservedObject private var settings = AppSettings.shared
    // Not ProcessStore itself: its revision changes on every sample, and menu content that
    // observes it is rebuilt each time, so open menus flicker and submenus close.
    @ObservedObject private var pause = PauseState.shared

    var body: some View {
        Button("System Information") { SystemInfoWindow.open() }
            .keyboardShortcut("i")
        Button("Resource History") { ResourceHistoryWindow.open() }
            .keyboardShortcut("g", modifiers: [.command, .option])
        Button("Refresh") { ProcessStore.shared.refreshNow() }
            .keyboardShortcut("r")
        Toggle("Pause Updates", isOn: Binding(get: { pause.paused }, set: { ProcessStore.shared.paused = $0 }))
            .keyboardShortcut("p", modifiers: [.command, .option])
        Picker("Update Interval", selection: $settings.refreshInterval) {
            ForEach([0.5, 1, 2, 3, 5, 10], id: \.self) { v in
                Text(v < 1 ? "\(Int(v * 1000)) ms" : "\(Int(v)) s").tag(v)
            }
        }
    }
}

/// `ProcessStore.paused` alone, for menus; see `ViewMenuUpdateItems`.
@MainActor
final class PauseState: ObservableObject {
    static let shared = PauseState()
    @Published private(set) var paused = ProcessStore.shared.paused
    private var subscription: AnyCancellable?

    private init() {
        subscription = ProcessStore.shared.$paused
            .removeDuplicates()
            .sink { [weak self] in self?.paused = $0 }
    }
}

struct ViewMenuFilterItems: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle("Show Processes as Tree", isOn: $settings.treeView)
            .keyboardShortcut("t", modifiers: [.command, .option])
        Toggle("Show Only Applications", isOn: $settings.onlyApplications)
            .keyboardShortcut("a", modifiers: [.command, .option])
        Toggle("Show Only My Processes", isOn: $settings.hideOtherUsers)
            .keyboardShortcut("u", modifiers: [.command, .option])
        Toggle("Hide System Processes", isOn: $settings.hideSystemProcesses)
        Toggle("Hide Apple-Signed Processes", isOn: $settings.hideAppleProcesses)
        Toggle("Hide Zombie Processes", isOn: $settings.hideZombies)
        Toggle("Show Only Applications Not Responding", isOn: $settings.onlyNotResponding)
        Button("Reset Process Filters") { settings.resetProcessFilters() }
            .disabled(!settings.hasProcessFilters)
        Divider()
        Toggle("Use Regular Expressions in Search", isOn: $settings.searchUsesRegex)
            .keyboardShortcut("r", modifiers: [.command, .option])
    }
}

struct ViewMenuWindowItems: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Picker("Appearance", selection: $settings.appearance) {
            ForEach(AppSettings.AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
        }
        Toggle("Fixed-Width Font in Process List", isOn: $settings.processListMonospaced)
        Toggle("Show Status Bar", isOn: $settings.showStatusBar)
        Toggle("Show in Menu Bar", isOn: $settings.showMenuBarExtra)
        Toggle("Always on Top", isOn: $settings.alwaysOnTop)
        Divider()
        Button("Find") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
            .keyboardShortcut("f")
    }
}

struct ProcessMenuItems: View {
    @ObservedObject private var selection = ProcessSelection.shared

    var body: some View {
        let items = selection.items.filter { !$0.isRemoved }
        ProcessMenuSignalItems(items: items)
        Divider()
        ProcessMenuInfoItems(items: items)
    }
}

struct ProcessMenuSignalItems: View {
    let items: [ProcessItem]

    var body: some View {
        Button("Terminate") { ProcessActions.terminate(items) }
            .keyboardShortcut(.delete)
            .disabled(items.isEmpty)
        Button("Terminate Tree") { ProcessActions.terminateTree(items) }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(items.isEmpty)
        Button("Force Kill") { ProcessActions.forceKill(items) }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .disabled(items.isEmpty)
        Divider()
        Button("Suspend") { ProcessActions.suspend(items) }.disabled(items.isEmpty)
        Button("Resume") { ProcessActions.resume(items) }.disabled(items.isEmpty)
        Button("Restart") { if let f = items.first { ProcessActions.restart(f) } }.disabled(items.count != 1)
        Menu("Priority") {
            ForEach(ProcessActions.priorities, id: \.0) { value, title in
                Button(title) { ProcessActions.setNice(items, value) }
            }
        }
        .disabled(items.isEmpty)
    }
}

struct ProcessMenuInfoItems: View {
    let items: [ProcessItem]

    var body: some View {
        Button("Sample Process…") { if let f = items.first { ProcessActions.sample(f) } }
            .disabled(items.count != 1)
        Button("Reveal in Finder") { if let f = items.first { ProcessActions.revealInFinder(f) } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(items.count != 1)
        Button("Properties") { if let f = items.first { PropertiesWindow.open(f) } }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(items.count != 1)
    }
}

struct ToolsMenuItems: View {
    var body: some View {
        Button("Find Files or Libraries…") { FindWindow.open() }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        Button("Inspect Executable…") { InspectorWindow.choose() }
        Button("Find Process by Window…") { WindowFinder.open() }
        Button("Hidden Process Scan…") { HiddenProcessesWindow.open() }
        Button("Event Log") { EventLogWindow.open() }
            .keyboardShortcut("l", modifiers: [.command, .option])
        Button("Crash Reports…") { CrashReportsWindow.open() }
        Button("Startup Items…") { StartupItemsWindow.open() }
        Button("Logged-in Users…") { UsersWindow.open() }
        Divider()
        Button("Purge Disk Cache…") {
            guard Alerts.confirm("Purge the disk cache?", message: "Flushes inactive file-backed memory (runs /usr/sbin/purge as root). The system may be slow briefly.", button: "Purge", destructive: false) else { return }
            Task { @MainActor in
                let out = await Reports.runTool("/usr/sbin/purge", [], requiresRoot: true)
                if !out.isEmpty { Alerts.info("Purge", out) }
            }
        }
        Button("Flush DNS Cache…") {
            Task { @MainActor in
                _ = await Reports.runTool("/usr/bin/dscacheutil", ["-flushcache"], requiresRoot: true)
                let out = await Reports.runTool("/usr/bin/killall", ["-HUP", "mDNSResponder"], requiresRoot: true)
                Alerts.info("DNS cache flushed", out.isEmpty ? "The DNS resolver cache was flushed." : out)
            }
        }
        Divider()
        Button("Stop Privileged Helper") { Elevation.shared.stopHelper() }
            .disabled(Elevation.shared.mode != .helper)
    }
}

/// Optional command line switches, e.g. `--tab network`, `--show-properties 1 --properties-tab files`,
/// `--elevate`, `--search <text>`, `--show-sysinfo cpu`, `--show-history`, `--show-find dyld`, `--inspect /bin/ls`, `--show-service com.apple.Finder`.
@MainActor
enum LaunchArguments {
    static func value(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func apply() {
        if CommandLine.arguments.contains("--elevate"), Elevation.shared.mode == .standard {
            Task { @MainActor in try? await Elevation.shared.startHelper() }
        }
        if let tab = value("--tab"), let t = MainTab.allCases.first(where: { $0.rawValue.lowercased() == tab.lowercased() }) {
            NotificationCenter.default.post(name: .showTab, object: t)
        }
        if let section = value("--show-sysinfo") {
            UserDefaults.standard.set(section.prefix(1).uppercased() + section.dropFirst(), forKey: "sysinfoSection")
            if section.lowercased() == "cpu" || section.lowercased() == "gpu" {
                UserDefaults.standard.set(section.uppercased(), forKey: "sysinfoSection")
            }
            SystemInfoWindow.open()
        }
        if CommandLine.arguments.contains("--show-history") { ResourceHistoryWindow.open() }
        if let pidText = value("--show-properties"), let pid = Int32(pidText), let item = ProcessStore.shared.item(pid: pid) {
            let tab = value("--properties-tab").flatMap { name in
                ProcessPropertiesView.PropertyTab.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
            }
            PropertiesWindow.open(item, tab: tab ?? .general)
        }
        if let q = value("--show-find") {
            UserDefaults.standard.set(q, forKey: "findQuery")
            FindWindow.open()
        }
        if let path = value("--inspect") {
            InspectorWindow.open(path: path)
        }
        if let label = value("--show-service") {
            ServiceStore.shared.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if let s = ServiceStore.shared.items.first(where: { $0.label == label }) {
                    ServicePropertiesWindow.open(s)
                }
            }
        }
        if CommandLine.arguments.contains("--relaunch-as-root"), Elevation.shared.mode != .root {
            do {
                try Elevation.relaunchAsRoot()
                NSApp.terminate(nil)
            } catch {}
        }
        if CommandLine.arguments.contains("--show-settings") {
            SettingsWindow.open()
        }
        if CommandLine.arguments.contains("--show-log") { EventLogWindow.open() }
        if CommandLine.arguments.contains("--show-crashes") { CrashReportsWindow.open() }
        if CommandLine.arguments.contains("--show-startup") { StartupItemsWindow.open() }
        if CommandLine.arguments.contains("--show-windows") { WindowFinder.open() }
        if let text = value("--search") {
            NotificationCenter.default.post(name: .showTab, object: MainTab.processes)
            ProcessStore.shared.filter.text = text
        }
        if let pidText = value("--select"), let pid = Int32(pidText) {
            ProcessSelection.shared.reveal(pid: pid)
        }
        if CommandLine.arguments.contains("--select-self") {
            ProcessSelection.shared.reveal(pid: getpid())
        }
    }
}
