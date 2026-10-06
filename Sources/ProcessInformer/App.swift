import AppKit
import InformerCore
import SwiftUI

@main
struct ProcessInformerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        Window("Process Informer", id: "main") {
            MainView()
                .environmentObject(settings)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }

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
        AppSettings.shared.apply()
        ProcessStore.shared.start()
        if AppSettings.shared.elevateAtLaunch, Elevation.shared.mode == .standard {
            Task { @MainActor in
                try? await Elevation.shared.startHelper()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Elevation.shared.stopHelper()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.shared.showMenuBarExtra
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) { FileMenuItems() }
        CommandGroup(after: .toolbar) {
            ViewMenuUpdateItems()
            Divider()
            ViewMenuFilterItems()
            Divider()
            ViewMenuWindowItems()
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
        Button("Export Process List…") {
            Alerts.save(text: ProcessSelection.shared.table.exportText(), suggestedName: "Processes.txt")
        }
        .keyboardShortcut("s")
        Button("Inspect Executable…") { InspectorWindow.choose() }
            .keyboardShortcut("o")
    }
}

struct ViewMenuUpdateItems: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = ProcessStore.shared

    var body: some View {
        Button("System Information") { SystemInfoWindow.open() }
            .keyboardShortcut("i")
        Button("Refresh") { store.refreshNow() }
            .keyboardShortcut("r")
        Toggle("Pause Updates", isOn: $store.paused)
            .keyboardShortcut("p", modifiers: [.command, .option])
        Picker("Update Interval", selection: $settings.refreshInterval) {
            ForEach([0.5, 1, 2, 3, 5, 10], id: \.self) { v in
                Text(v < 1 ? "\(Int(v * 1000)) ms" : "\(Int(v)) s").tag(v)
            }
        }
    }
}

struct ViewMenuFilterItems: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle("Show Processes as Tree", isOn: $settings.treeView)
            .keyboardShortcut("t", modifiers: [.command, .option])
        Toggle("Hide Processes from Other Users", isOn: $settings.hideOtherUsers)
        Toggle("Hide System Processes", isOn: $settings.hideSystemProcesses)
        Toggle("Hide Apple-Signed Processes", isOn: $settings.hideAppleProcesses)
        Toggle("Hide Zombie Processes", isOn: $settings.hideZombies)
    }
}

struct ViewMenuWindowItems: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
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
        Button("Hidden Process Scan…") { HiddenProcessesWindow.open() }
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
