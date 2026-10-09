import AppKit
import ProcopticonCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, appearance, filters, highlighting, alerts, privileges

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .filters: return "Filters"
        case .highlighting: return "Highlighting"
        case .alerts: return "Alerts"
        case .privileges: return "Privileges"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .highlighting: return "paintpalette"
        case .alerts: return "bell.badge"
        case .privileges: return "lock.shield"
        }
    }

    /// Each tab has its own size and the window resizes to fit, like other Mac settings windows.
    var size: NSSize {
        switch self {
        case .general: return NSSize(width: 620, height: 620)
        case .appearance: return NSSize(width: 620, height: 500)
        case .filters: return NSSize(width: 620, height: 600)
        case .highlighting: return NSSize(width: 620, height: 640)
        case .alerts: return NSSize(width: 720, height: 560)
        case .privileges: return NSSize(width: 620, height: 380)
        }
    }

    @MainActor @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .filters: SavedFiltersSettings()
        case .highlighting: HighlightSettings()
        case .alerts: AlertSettings()
        case .privileges: PrivilegeSettings()
        }
    }
}

/// The Settings window. Switching tabs works like Finder's and Calendar's settings: the old tab
/// goes away, the window animates to the new tab's size, and only then is the new tab drawn. A
/// SwiftUI `Settings` scene swapped the new tab in first and resized the window around it.
@MainActor
final class SettingsWindow: NSObject, NSToolbarDelegate, NSWindowDelegate {
    static let shared = SettingsWindow()

    static func open(tab: SettingsTab? = nil) {
        shared.show(tab ?? shared.storedTab)
    }

    private let model = SettingsWindowModel()
    private var window: NSWindow?
    /// Bumped on each switch, so a resize that finishes after another switch began shows nothing.
    private var switches = 0

    private var storedTab: SettingsTab {
        SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .general
    }

    private func show(_ tab: SettingsTab) {
        let window = self.window ?? makeWindow(tab)
        select(tab, animate: window.isVisible)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(_ tab: SettingsTab) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: tab.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        let host = NSHostingView(rootView: SettingsContent(model: model).environmentObject(AppSettings.shared))
        // The window's size is set here, per tab; the content never resizes it.
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(frame(for: tab, in: window), display: false)
        if !window.setFrameUsingName("Settings") {
            window.center()
        }
        window.setFrameAutosaveName("Settings")
        self.window = window
        return window
    }

    private func select(_ tab: SettingsTab, animate: Bool) {
        guard let window else { return }
        UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
        window.title = tab.title
        guard model.shown != tab else { return }
        switches += 1
        let current = switches
        let frame = frame(for: tab, in: window)
        guard animate, frame != window.frame else {
            window.setFrame(frame, display: true)
            model.shown = tab
            return
        }
        model.shown = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window.animationResizeTime(frame)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            guard let self, self.switches == current else { return }
            self.model.shown = tab
        }
    }

    /// The window frame that fits `tab` below the toolbar, keeping the top-left corner in place.
    private func frame(for tab: SettingsTab, in window: NSWindow) -> NSRect {
        let chrome = window.frame.height - window.contentLayoutRect.height
        let height = tab.size.height + chrome
        return NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: tab.size.width, height: height)
    }

    @objc private func selectItem(_ item: NSToolbarItem) {
        if let tab = SettingsTab(rawValue: item.itemIdentifier.rawValue) {
            select(tab, animate: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Nothing keeps updating while the window is closed; the tab is rebuilt when it reopens.
        switches += 1
        model.shown = nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectItem(_:))
        return item
    }
}

@MainActor
private final class SettingsWindowModel: ObservableObject {
    /// The tab on show; nil while the window resizes for another one.
    @Published var shown: SettingsTab?
}

private struct SettingsContent: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        ZStack(alignment: .top) {
            // The background stays while the window resizes, so only the controls come and go.
            Color.clear.settingsPane()
            if let tab = model.shown {
                tab.content.frame(width: tab.size.width, height: tab.size.height)
            }
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
                Toggle("Confirm before terminating or changing processes", isOn: $settings.confirmActions)
                TextField("Online search URL (%s = name)", text: $settings.searchEngineURL)
                Picker("Search text is", selection: $settings.processSearchMode) {
                    Text("Plain text").tag(SearchMode.text)
                    Text("A regular expression").tag(SearchMode.regex)
                    Text("A JavaScript expression (process list)").tag(SearchMode.javascript)
                }
                Text("""
                    Regular expressions apply to every search field, JavaScript to the process list (other lists then \
                    match plain text). In plain text, /pattern/ is a regular expression all the same; add c after the \
                    closing slash for case-sensitive matching.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window") {
                Toggle("Keep main window on top", isOn: $settings.alwaysOnTop)
            }
            Section("Network") {
                Toggle("Resolve remote addresses to host names", isOn: $settings.resolveAddresses)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .settingsPane()
    }
}

struct AppearanceSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Light or dark windows, or System to follow the macOS setting")
                if AccentColor.isSupported {
                    LabeledContent("Accent color") {
                        AccentSwatches(selection: $settings.accent, custom: $settings.accentCustom)
                    }
                }
            } footer: {
                if AccentColor.isSupported, settings.accent != .system, AccentColor.systemOverrides {
                    Text("System Settings ▸ Appearance has an accent color chosen, and macOS uses it instead. Set it to Multicolor there to use this one.")
                }
            }
            Section("Process list") {
                Toggle("Fixed-width font", isOn: $settings.processListMonospaced)
                Picker("Font size", selection: $settings.processListFontSize) {
                    ForEach([10.0, 11, 12, 13, 14, 15, 16], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
            }
            Section("Main window") {
                Toggle("Show status bar", isOn: $settings.showStatusBar)
            }
            Section("Menu bar") {
                Toggle("Show graph in menu bar", isOn: $settings.showMenuBarExtra)
                Picker("Menu bar graph", selection: $settings.menuBarGraph) {
                    ForEach(AppSettings.MenuBarGraphKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!settings.showMenuBarExtra)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .settingsPane()
    }
}

/// A row of color swatches like System Settings' accent colors: System (multicolor), the palette,
/// then a color well for any other color.
struct AccentSwatches: View {
    @Binding var selection: AppSettings.AccentChoice
    @Binding var custom: NSColor

    var body: some View {
        HStack(spacing: 7) {
            ForEach(AppSettings.AccentChoice.allCases.filter { $0 != .custom }) { choice in
                Button { selection = choice } label: {
                    swatch(choice)
                }
                .buttonStyle(.plain)
                .help(choice == .system ? "Use the accent color from System Settings" : choice.title)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
            ColorPicker("Custom", selection: Binding(get: { Color(nsColor: custom) },
                                                     set: { custom = NSColor($0); selection = .custom }),
                        supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .padding(2)
                .overlay(Capsule().strokeBorder(.primary.opacity(selection == .custom ? 0.6 : 0), lineWidth: 1.5))
                .help("Any other color")
        }
    }

    private func swatch(_ choice: AppSettings.AccentChoice) -> some View {
        let fill: AnyShapeStyle = choice == .system
            ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
            : AnyShapeStyle(Color(nsColor: choice.color(custom: custom) ?? .controlAccentColor))
        return Circle()
            .fill(fill)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .padding(2.5)
            .overlay(Circle().strokeBorder(.primary.opacity(selection == choice ? 0.6 : 0), lineWidth: 1.5))
            .contentShape(Circle())
    }
}

struct HighlightSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("highlightSettingsTab") private var tab = Tab.builtIn

    enum Tab: String, CaseIterable, Identifiable {
        case builtIn, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .builtIn: return "Built-in Rules"
            case .custom: return "Custom Rules"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Rules", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)
            switch tab {
            case .builtIn: builtIn
            case .custom: custom
            }
        }
        .settingsPane()
    }

    private var builtIn: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(HighlightRule.allCases) { rule in
                        HStack {
                            Toggle(rule.title, isOn: Binding(
                                get: { settings.highlights[rule]?.enabled ?? false },
                                set: { settings.highlights[rule]?.enabled = $0 }))
                                .toggleStyle(.checkbox)
                            Spacer()
                            ColorPicker("", selection: Binding(
                                get: { Color(nsColor: settings.highlights[rule]?.color ?? .clear) },
                                set: { settings.highlights[rule]?.color = NSColor($0) }), supportsOpacity: false)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                    }
                } footer: {
                    Text("""
                        Rules are listed from highest to lowest priority. Custom rules come after terminated and \
                        new processes, before the rest.
                        """)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Enable All") { settings.setAllHighlights(enabled: true) }
                    .disabled(settings.highlights.values.allSatisfy(\.enabled))
                    .help("Turn on every built-in rule")
                Button("Disable All") { settings.setAllHighlights(enabled: false) }
                    .disabled(!settings.highlights.values.contains(where: \.enabled))
                    .help("Turn off every built-in rule; their colors are kept")
                Button("Restore Defaults") { settings.resetHighlights() }
                    .help("Restore the built-in rules and their colors")
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    private var custom: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if settings.customHighlights.isEmpty {
                        Text("No custom rules. Add one to color the processes that match text, a regular expression or a JavaScript expression.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($settings.customHighlights) { $rule in
                        CustomHighlightRow(rule: $rule, menu: { menu(for: rule.id) })
                    }
                } footer: {
                    Text("""
                        A rule matches processes as the search field does: by text, a regular expression, or a \
                        JavaScript expression over the process's values, such as memory > 2 * GB. The first rule a \
                        process matches colors it. Custom rules come after terminated and new processes and before \
                        the other built-in rules.
                        """)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Button {
                    settings.customHighlights.append(CustomHighlight())
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .help("Add a rule that colors the processes a filter matches")
                Spacer()
                Button("Enable All") { settings.setAllCustomHighlights(enabled: true) }
                    .disabled(settings.customHighlights.allSatisfy(\.enabled))
                    .help("Turn on every custom rule")
                Button("Disable All") { settings.setAllCustomHighlights(enabled: false) }
                    .disabled(!settings.customHighlights.contains(where: \.enabled))
                    .help("Turn off every custom rule")
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    @ViewBuilder
    private func menu(for id: CustomHighlight.ID) -> some View {
        let rules = settings.customHighlights
        if let i = rules.firstIndex(where: { $0.id == id }) {
            Button("Move Up") { settings.customHighlights.swapAt(i, i - 1) }
                .disabled(i == 0)
            Button("Move Down") { settings.customHighlights.swapAt(i, i + 1) }
                .disabled(i == rules.count - 1)
            Divider()
            Button("Duplicate") {
                var copy = rules[i]
                copy.id = UUID()
                settings.customHighlights.insert(copy, at: i + 1)
            }
            Button("Delete") { settings.customHighlights.remove(at: i) }
        }
    }
}

/// One custom highlight rule: whether it's on, its name, color and expression.
private struct CustomHighlightRow<Actions: View>: View {
    @Binding var rule: CustomHighlight
    @ViewBuilder var menu: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Enabled", isOn: $rule.enabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(rule.enabled ? "Turn this rule off" : "Turn this rule on")
                TextField("Name", text: $rule.name, prompt: Text("Name (optional)"))
                    .labelsHidden()
                ColorPicker("Color", selection: Binding(
                    get: { Color(nsColor: rule.color) },
                    set: { rule.color = NSColor($0) }), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Move, duplicate or delete this rule")
            }
            FilterEditor(text: $rule.text, mode: $rule.mode, emptyStatus: "Matches nothing until it has something to match.")
                .padding(.leading, 22)
                .opacity(rule.enabled ? 1 : 0.6)
        }
        .padding(.vertical, 2)
        .contextMenu { menu() }
    }
}

/// Lays out a settings tab below the tab bar, on the grouped-form background.
private struct SettingsPane: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Off the top edge by a point: a scroll view touching it extends up under the tab bar,
            // and on macOS 26 hovering over the bar then lit it up (over just one column, in Filters).
            .padding(.top, 1)
            // An empty grouped form draws the usual background, including under the tab bar, without
            // reacting to the pointer; the tab's own forms hide their background so it isn't drawn twice.
            .background {
                Form {}
                    .formStyle(.grouped)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func settingsPane() -> some View {
        modifier(SettingsPane())
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
                        .help("Quit the privileged helper; other users' processes show limited details again")
                case .standard:
                    Text("Only your own processes can be fully inspected. Actions on other users' processes will ask for administrator credentials once per session.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show Details for All Processes…") {
                        Task { @MainActor in
                            try? await Elevation.shared.startHelper()
                            revision &+= 1
                        }
                    }
                    .help("Authorize once (administrator password) to see every process in full for this session")
                }
                Button("Relaunch as Root…") {
                    do {
                        try Elevation.relaunchAsRoot()
                        NSApp.terminate(nil)
                    } catch let e as PrivilegedError where e == .cancelled {
                    } catch {
                        Alerts.error("Unable to relaunch", error.localizedDescription)
                    }
                }
                .help("Quit and start Procopticon again as root (asks for an administrator password)")
                .disabled(mode == .root)
            }
            Section("Startup") {
                Toggle("Authorize at launch (show details for all processes)", isOn: $settings.elevateAtLaunch)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .settingsPane()
        .id(revision)
        .onReceive(NotificationCenter.default.publisher(for: Elevation.didChangeNotification)) { _ in revision &+= 1 }
    }
}
