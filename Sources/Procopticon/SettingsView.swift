import AppKit
import ProcopticonCore
import SwiftUI

enum SettingsTab: String, Hashable {
    case general, filters, highlighting, privileges
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        // Each tab sets its own size and the window resizes to fit, like other Mac settings windows.
        TabView(selection: $tab) {
            GeneralSettings()
                .frame(width: 620, height: 500)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SavedFiltersSettings()
                .frame(width: 620, height: 600)
                .tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
                .tag(SettingsTab.filters)
            HighlightSettings()
                .frame(width: 620, height: 500)
                .tabItem { Label("Highlighting", systemImage: "paintpalette") }
                .tag(SettingsTab.highlighting)
            PrivilegeSettings()
                .frame(width: 620, height: 500)
                .tabItem { Label("Privileges", systemImage: "lock.shield") }
                .tag(SettingsTab.privileges)
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Updates") {
                Picker("Update interval", selection: $settings.refreshInterval) {
                    ForEach([0.5, 1, 2, 3, 5, 10], id: \.self) { v in
                        Text(v < 1 ? "\(Int(v * 1000)) ms" : (v == 1 ? "1 second" : "\(Int(v)) seconds")).tag(v)
                    }
                }
                Picker("Highlight new/terminated items for", selection: $settings.highlightDuration) {
                    ForEach([0.0, 1, 2, 3, 5, 10], id: \.self) { v in
                        Text(v == 0 ? "Don't highlight" : (v == 1 ? "1 second" : "\(Int(v)) seconds")).tag(v)
                    }
                }
            }
            Section("Processes") {
                Picker("CPU usage", selection: $settings.cpuScaleToSystem) {
                    Text("Percent of total system capacity").tag(true)
                    Text("Percent of one core (100% per core)").tag(false)
                }
                Toggle("Show processes as a tree", isOn: $settings.treeView)
                Toggle("Fixed-width font in the process list", isOn: $settings.processListMonospaced)
                Picker("Process list font size", selection: $settings.processListFontSize) {
                    ForEach([10.0, 11, 12, 13, 14, 15, 16], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                Toggle("Confirm before terminating or changing processes", isOn: $settings.confirmActions)
                TextField("Online search URL (%s = name)", text: $settings.searchEngineURL)
                Toggle("Treat search text as a regular expression", isOn: $settings.searchUsesRegex)
                Text("Regardless of this setting, text written as /pattern/ is a regular expression (add c after the closing slash for case-sensitive matching).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window") {
                Toggle("Show status bar", isOn: $settings.showStatusBar)
                Toggle("Keep main window on top", isOn: $settings.alwaysOnTop)
                Toggle("Show graph in menu bar", isOn: $settings.showMenuBarExtra)
                Picker("Menu bar graph", selection: $settings.menuBarGraph) {
                    ForEach(AppSettings.MenuBarGraphKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!settings.showMenuBarExtra)
            }
            Section("Network") {
                Toggle("Resolve remote addresses to host names", isOn: $settings.resolveAddresses)
            }
        }
        .formStyle(.grouped)
    }
}

struct HighlightSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(HighlightRule.allCases) { rule in
                    HStack {
                        Toggle(rule.title, isOn: Binding(
                            get: { settings.highlights[rule]?.enabled ?? false },
                            set: { settings.highlights[rule]?.enabled = $0 }))
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: settings.highlights[rule]?.color ?? .clear) },
                            set: { settings.highlights[rule]?.color = NSColor($0) }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
            HStack {
                Text("Rules are listed from highest to lowest priority.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Enable All") { settings.setAllHighlights(enabled: true) }
                    .disabled(settings.highlights.values.allSatisfy(\.enabled))
                    .help("Turn on every highlight rule")
                Button("Disable All") { settings.setAllHighlights(enabled: false) }
                    .disabled(!settings.highlights.values.contains(where: \.enabled))
                    .help("Turn off every highlight rule; their colors are kept")
                Button("Restore Defaults") { settings.resetHighlights() }
                    .help("Restore the default rules and colors")
            }
            .padding(8)
        }
        .padding(8)
    }
}

struct PrivilegeSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var revision = 0

    var body: some View {
        let mode = Elevation.shared.mode
        Form {
            Section("Current mode") {
                LabeledContent("Mode", value: mode.rawValue)
                LabeledContent("Interactive user", value: UserNames.name(Elevation.interactiveUid))
                switch mode {
                case .root:
                    Text("Running as root. All processes are fully visible and privileged actions run without prompting.")
                        .font(.caption).foregroundStyle(.secondary)
                case .helper:
                    Text("A privileged helper is serving this session. It only accepts connections from this app's process and exits when the app quits.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Stop Helper") { Elevation.shared.stopHelper(); revision &+= 1 }
                case .standard:
                    Text("Only your own processes can be fully inspected. Actions on other users' processes will ask for administrator credentials once per session.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show Details for All Processes…") {
                        Task { @MainActor in
                            try? await Elevation.shared.startHelper()
                            revision &+= 1
                        }
                    }
                }
            }
            Section("Startup") {
                Toggle("Authorize at launch (show details for all processes)", isOn: $settings.elevateAtLaunch)
            }
            Section("Sudo mode") {
                Text("To run without any authorization prompts, start Procopticon as root from Terminal:")
                    .font(.caption)
                Text("sudo \"\(Bundle.main.executablePath ?? "/Applications/Procopticon.app/Contents/MacOS/Procopticon")\"")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Relaunch as Root…") {
                    do {
                        try Elevation.relaunchAsRoot()
                        NSApp.terminate(nil)
                    } catch let e as PrivilegedError where e == .cancelled {
                    } catch {
                        Alerts.error("Unable to relaunch", error.localizedDescription)
                    }
                }
                .disabled(mode == .root)
            }
        }
        .formStyle(.grouped)
        .id(revision)
        .onReceive(NotificationCenter.default.publisher(for: Elevation.didChangeNotification)) { _ in revision &+= 1 }
    }
}
