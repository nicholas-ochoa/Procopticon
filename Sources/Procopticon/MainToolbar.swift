import AppKit
import Combine
import ProcopticonCore
import SwiftUI

/// What a plain toolbar button does.
enum ToolbarAction: Int, CaseIterable {
    case sysinfo, history, find, settings, properties, terminate, kill, inspect, run, log, crashes, startup, windows, users, export, refresh

    @MainActor
    func perform() {
        switch self {
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
        case .export: TableExport.saveProcessList()
        case .refresh:
            ProcessStore.shared.refreshNow()
            if MainWindowState.shared.tab == .services { ServiceStore.shared.refresh() }
            if MainWindowState.shared.tab == .network { NetworkStore.shared.refresh() }
        }
    }

    var title: String {
        switch self {
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
        case .export: return "Export"
        case .refresh: return "Refresh"
        }
    }

    var symbol: String {
        switch self {
        case .sysinfo: return "gauge.with.needle"
        case .history: return "chart.xyaxis.line"
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
        case .export: return "square.and.arrow.up"
        case .refresh: return "arrow.clockwise"
        }
    }

    var help: String {
        switch self {
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
        case .export: return "Save the visible process list as JSON or CSV (⌘S)"
        case .refresh: return "Update all data now instead of waiting for the next refresh (⌘R)"
        }
    }

    var image: NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
    }
}

private extension NSToolbarItem.Identifier {
    static let title = Self("title")
    static let tabs = Self("tabs")
    static let search = Self("search")
    static let filtersGroup = Self("group.filters")
    static let updatesGroup = Self("group.updates")
    static let toolsGroup = Self("group.tools")
    static let privilegesGroup = Self("group.privileges")
    static let processGroup = Self("group.process")
    static let windowsGroup = Self("group.windows")
    static let filesGroup = Self("group.files")
    static let apps = Self("apps")
    static let mine = Self("mine")
    static let treeList = Self("treeList")
    static let filters = Self("filters")
    static let pause = Self("pause")
    static let elevate = Self("elevate")

    /// The item for one action on its own.
    static func action(_ action: ToolbarAction) -> Self { Self("action.\(action)") }
}

/// The main window's toolbar (View ▸ Customize Toolbar…), built in AppKit.
///
/// The title and the tab picker stay fixed on the left; the buttons sit on the right, in groups
/// separated by fixed spaces. Every group and every individual button is also offered in the
/// palette.
///
/// It was a SwiftUI `.toolbar` before. Bridging that to the window's toolbar was the largest single
/// part of opening the window, about 140 ms of the main thread at launch.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    static let shared = MainToolbar()

    private let toolbar = NSToolbar(identifier: "MainToolbar")
    private weak var window: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// The search field in the toolbar (not the palette's copy) and what drives it.
    private weak var searchItem: NSSearchToolbarItem?
    private var searchCoordinator: RegexSearchFieldView.Coordinator?
    /// The line under the name in the title item: how many processes there are.
    private let subtitle = NSTextField(labelWithString: "")

    private static let groupActions: [NSToolbarItem.Identifier: (title: String, actions: [ToolbarAction])] = [
        .toolsGroup: ("Tools", [.sysinfo, .history, .find]),
        .processGroup: ("Process Actions", [.properties, .terminate, .kill]),
        .windowsGroup: ("Inspection Windows", [.log, .crashes, .startup, .windows, .users]),
        .filesGroup: ("Files & Programs", [.inspect, .run, .export]),
    ]
    /// Actions offered one at a time in the palette, in its order.
    private static let individualActions: [ToolbarAction] = [
        .refresh, .settings, .properties, .terminate, .kill, .export, .inspect, .run,
        .sysinfo, .history, .find, .log, .crashes, .startup, .windows, .users,
    ]
    /// Items that only mean something for the process list.
    private static let processesOnly: Set<NSToolbarItem.Identifier> = [.filtersGroup, .apps, .mine, .treeList, .filters]

    private override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
    }

    /// Puts the toolbar on the main window and keeps it and the window's subtitle up to date.
    func install(on window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.toolbarStyle = .unified
        // The title is an item of the toolbar (see `titleItem`), so that the tabs can follow it.
        window.titleVisibility = .hidden
        window.toolbar = toolbar
        guard subscriptions.isEmpty else { return }

        let state = MainWindowState.shared
        // Published values arrive before they are set, so each of these looks again a moment later.
        let later = DispatchQueue.main
        state.objectWillChange.receive(on: later).sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        AppSettings.shared.objectWillChange.receive(on: later).sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        ProcessSelection.shared.objectWillChange.receive(on: later).sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        PauseState.shared.objectWillChange.receive(on: later).sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        ProcessStore.shared.$revision.receive(on: later).map { _ in ProcessStore.shared.processCount }.removeDuplicates()
            .sink { [weak self] in self?.subtitle.stringValue = $0 == 1 ? "1 process" : "\(Fmt.count($0)) processes" }
            .store(in: &subscriptions)
        observers.append(NotificationCenter.default.addObserver(forName: .focusSearch, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusSearch() }
        })
    }

    // MARK: Delegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Refresh (⌘R) and Settings (⌘,) are in the menus and in the palette, not here.
        [.title, .tabs, .flexibleSpace, .filtersGroup, .space, .updatesGroup, .space, .toolsGroup, .space, .privilegesGroup, .space, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.title, .tabs, .filtersGroup, .updatesGroup, .toolsGroup, .privilegesGroup, .search,
         .processGroup, .windowsGroup, .filesGroup, .apps, .mine, .treeList, .filters, .pause, .elevate]
            + Self.individualActions.map { .action($0) }
            + [.space, .flexibleSpace]
    }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.title, .tabs]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar inserted: Bool) -> NSToolbarItem? {
        guard let item = makeItem(identifier, inserted: inserted) else { return nil }
        item.autovalidates = false
        refresh(item)
        return item
    }

    // MARK: Items

    private func makeItem(_ identifier: NSToolbarItem.Identifier, inserted: Bool) -> NSToolbarItem? {
        switch identifier {
        case .title:
            return titleItem()
        case .tabs:
            let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: MainTab.allCases.map(\.rawValue), selectionMode: .selectOne,
                                           labels: MainTab.allCases.map(\.rawValue), target: self, action: #selector(tabChosen(_:)))
            group.label = "View"
            group.paletteLabel = "View"
            group.controlRepresentation = .expanded
            group.isNavigational = true
            group.toolTip = "Switch between processes, launchd services, network connections and disk activity"
            for (subitem, tab) in zip(group.subitems, MainTab.allCases) {
                subitem.toolTip = tab.help
            }
            return group
        case .filtersGroup:
            return toggleGroup(identifier, "Quick Filters", [
                ("Apps", "square.grid.2x2", "Show only applications with a user interface and the processes they started (⌥⌘A)"),
                ("Mine", "person", "Show only processes running as you, hiding other users and system accounts (⌥⌘U)"),
                ("List", "list.bullet", "Show processes as a flat list (⌥⌘T)"),
                ("Tree", "list.bullet.indent", "Show processes as a parent/child tree (⌥⌘T)"),
                ("Filters", nil, Self.filtersHelp),
            ], action: #selector(quickFilterChosen(_:)))
        case .apps:
            return toggleGroup(identifier, "Apps", [
                ("Apps", "square.grid.2x2", "Show only applications with a user interface and the processes they started (⌥⌘A)"),
            ], action: #selector(appsToggled(_:)))
        case .mine:
            return toggleGroup(identifier, "Mine", [
                ("Mine", "person", "Show only processes running as you, hiding other users and system accounts (⌥⌘U)"),
            ], action: #selector(mineToggled(_:)))
        case .treeList:
            return toggleGroup(identifier, "List or Tree", [
                ("List", "list.bullet", "Show processes as a flat list (⌥⌘T)"),
                ("Tree", "list.bullet.indent", "Show processes as a parent/child tree (⌥⌘T)"),
            ], action: #selector(treeListChosen(_:)))
        case .filters:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Filters"
            item.paletteLabel = "Filters"
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filters")
            item.toolTip = Self.filtersHelp
            item.showsIndicator = true
            item.menu = FiltersMenuSource.shared.menu
            return item
        case .updatesGroup, .pause:
            return toggleGroup(identifier, identifier == .pause ? "Pause" : "Updates", [("Pause", "pause.fill", "")], action: #selector(pauseToggled(_:)))
        case .privilegesGroup, .elevate:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.paletteLabel = identifier == .elevate ? "Show Details for All Processes" : "Privileges"
            item.isBordered = true
            item.target = self
            item.action = #selector(elevate(_:))
            return item
        case .search:
            return makeSearchItem(inserted: inserted)
        default:
            if let group = Self.groupActions[identifier] {
                let item = NSToolbarItemGroup(itemIdentifier: identifier, images: group.actions.map(\.image), selectionMode: .momentary,
                                              labels: group.actions.map(\.title), target: self, action: #selector(groupActionChosen(_:)))
                item.label = group.title
                item.paletteLabel = group.title
                item.controlRepresentation = .expanded
                for (subitem, action) in zip(item.subitems, group.actions) {
                    subitem.toolTip = action.help
                }
                return item
            }
            guard let action = Self.individualActions.first(where: { NSToolbarItem.Identifier.action($0) == identifier }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = action.title
            item.paletteLabel = action.title
            item.image = action.image
            item.toolTip = action.help
            item.isBordered = true
            item.tag = action.rawValue
            item.target = self
            item.action = #selector(actionChosen(_:))
            return item
        }
    }

    /// The app's name over the number of processes: plain text, not a button.
    private func titleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .title)
        item.label = "Procopticon"
        item.paletteLabel = "Title"
        item.isNavigational = true
        item.isBordered = false
        let name = NSTextField(labelWithString: "Procopticon")
        name.font = .preferredFont(forTextStyle: .headline)
        subtitle.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [name, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        item.view = stack
        return item
    }

    private static let filtersHelp = "More filters (hide system, Apple-signed or zombie processes, show hung applications) and your saved filters"

    /// A group whose buttons stay pressed in while what they stand for is on. Which are on is set
    /// from the settings (see `refresh`), never left to the clicks.
    private func toggleGroup(_ identifier: NSToolbarItem.Identifier, _ title: String,
                             _ parts: [(label: String, symbol: String?, help: String)], action: Selector) -> NSToolbarItemGroup {
        let images = parts.map { part in
            part.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: part.label) } ?? Self.filtersMenuImage
        }
        let group = NSToolbarItemGroup(itemIdentifier: identifier, images: images, selectionMode: .selectAny,
                                       labels: parts.map(\.label), target: self, action: action)
        group.label = title
        group.paletteLabel = title
        group.controlRepresentation = .expanded
        for (subitem, part) in zip(group.subitems, parts) {
            subitem.toolTip = part.help
        }
        return group
    }

    /// The filters funnel with the small chevron that marks a button as opening a menu.
    private static let filtersMenuImage: NSImage = {
        // At the size the toolbar draws its own symbols, since this one is handed over as a drawing.
        guard let funnel = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filters")?
                  .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)),
              let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                  .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)) else { return NSImage() }
        let gap: CGFloat = 3
        let size = NSSize(width: funnel.size.width + gap + chevron.size.width, height: max(funnel.size.height, chevron.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            funnel.draw(in: NSRect(x: 0, y: (size.height - funnel.size.height) / 2, width: funnel.size.width, height: funnel.size.height))
            chevron.draw(in: NSRect(x: funnel.size.width + gap, y: (size.height - chevron.size.height) / 2,
                                    width: chevron.size.width, height: chevron.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Filters"
        return image
    }()

    private func makeSearchItem(inserted: Bool) -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: .search)
        item.label = "Search"
        item.paletteLabel = "Search"
        item.preferredWidthForSearchField = 260
        // The palette's copy is only looked at; the one in the toolbar gets the real field.
        guard inserted else { return item }
        searchCoordinator?.stopCompleting()
        let configuration = searchConfiguration
        let coordinator = RegexSearchFieldView.Coordinator(configuration)
        item.searchField = configuration.makeField(coordinator: coordinator)
        searchCoordinator = coordinator
        searchItem = item
        return item
    }

    /// The search field's text, toggles and prompt for the tab that is showing.
    private var searchConfiguration: RegexSearchFieldView {
        let state = MainWindowState.shared
        let settings = AppSettings.shared
        let processes = state.tab == .processes
        return RegexSearchFieldView(
            text: state.searchBinding,
            regex: Binding(get: { settings.searchUsesRegex }, set: { settings.searchUsesRegex = $0 }),
            javaScript: processes ? Binding(get: { settings.searchUsesJavaScript }, set: { settings.searchUsesJavaScript = $0 }) : nil,
            prompt: processes ? "Search processes" : "Search \(state.tab.rawValue.lowercased())",
            toolTip: processes
                ? "Filter the list by name, PID, path, command line or user. Click .* for a regular expression, or {} for a JavaScript expression such as cpu > 10 && user == \"root\" (⌘F)"
                : "Filter the list. Click .* or write /pattern/ for a regular expression (⌘F)")
    }

    private func focusSearch() {
        guard let searchItem else { return }
        searchItem.beginSearchInteraction()
        window?.makeFirstResponder(searchItem.searchField)
    }

    // MARK: State

    /// Brings every item in the toolbar in line with the app's state.
    private func refresh() {
        toolbar.items.forEach(refresh)
    }

    private func refresh(_ item: NSToolbarItem) {
        let settings = AppSettings.shared
        let tab = MainWindowState.shared.tab
        let identifier = item.itemIdentifier
        if Self.processesOnly.contains(identifier) {
            item.isEnabled = tab == .processes
        }
        let group = item as? NSToolbarItemGroup
        func select(_ states: [Bool]) {
            // A group that is switched off shows nothing pressed in: a lit button looks live.
            for (index, on) in states.enumerated() where group?.isSelected(at: index) != (on && item.isEnabled) {
                group?.setSelected(on && item.isEnabled, at: index)
            }
        }
        switch identifier {
        case .tabs:
            let index = MainTab.allCases.firstIndex(of: tab) ?? 0
            if group?.selectedIndex != index { group?.selectedIndex = index }
        case .filtersGroup:
            select(quickFilterStates)
        case .apps:
            select([settings.onlyApplications])
        case .mine:
            select([settings.hideOtherUsers])
        case .treeList:
            select([!settings.treeView, settings.treeView])
        case .updatesGroup, .pause:
            let paused = ProcessStore.shared.paused
            select([paused])
            let subitem = group?.subitems.first
            subitem?.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Resume" : "Pause")
            subitem?.label = paused ? "Resume" : "Pause"
            subitem?.toolTip = paused
                ? "Updates are paused. Click to resume live updates (⌥⌘P)"
                : "Pause live updates so the lists stop changing while you look (⌥⌘P)"
        case .privilegesGroup, .elevate:
            // An empty shield without administrator rights; a filled orange one with them.
            let mode = Elevation.shared.mode
            let title = mode == .standard ? "Show Details for All Processes" : "Elevated"
            item.label = title
            item.image = mode == .standard
                ? NSImage(systemSymbolName: "shield", accessibilityDescription: title)
                : NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: title)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
            item.toolTip = mode == .standard
                ? "Authorize once (administrator password) to see every process in full and act on other users' processes"
                : "Running with administrator rights (\(mode.rawValue)). Click for details"
        case .search:
            if item === searchItem, let coordinator = searchCoordinator, let field = searchItem?.searchField as? RegexSearchField {
                searchConfiguration.apply(to: field, coordinator: coordinator)
            }
        default:
            break
        }
    }

    /// Apps, Mine, List, Tree and whether any of the Filters menu's filters is on.
    private var quickFilterStates: [Bool] {
        let settings = AppSettings.shared
        let filtering = settings.hideSystemProcesses || settings.hideAppleProcesses || settings.hideZombies || settings.onlyNotResponding
            || settings.activeSavedFilter != nil || ProcessSelection.shared.focused != nil
        return [settings.onlyApplications, settings.hideOtherUsers, !settings.treeView, settings.treeView, filtering]
    }

    // MARK: Actions

    @objc private func tabChosen(_ group: NSToolbarItemGroup) {
        let index = group.selectedIndex
        guard MainTab.allCases.indices.contains(index) else { return }
        MainWindowState.shared.tab = MainTab.allCases[index]
    }

    /// The click has already flipped one button of the group; that one differs from the settings.
    @objc private func quickFilterChosen(_ group: NSToolbarItemGroup) {
        let settings = AppSettings.shared
        let clicked = quickFilterStates.indices.first { group.isSelected(at: $0) != quickFilterStates[$0] }
        switch clicked {
        case 0: settings.onlyApplications.toggle()
        case 1: settings.hideOtherUsers.toggle()
        case 2: settings.treeView = false
        case 3: settings.treeView = true
        case 4:
            refresh(group)
            popUpFiltersMenu()
        default: break
        }
        refresh(group)
    }

    @objc private func appsToggled(_ group: NSToolbarItemGroup) {
        AppSettings.shared.onlyApplications.toggle()
        refresh(group)
    }

    @objc private func mineToggled(_ group: NSToolbarItemGroup) {
        AppSettings.shared.hideOtherUsers.toggle()
        refresh(group)
    }

    @objc private func treeListChosen(_ group: NSToolbarItemGroup) {
        let settings = AppSettings.shared
        // The click flipped one of the two; the one that now disagrees with the setting was clicked.
        if group.isSelected(at: 0) == settings.treeView {
            settings.treeView = !group.isSelected(at: 0)
        } else if group.isSelected(at: 1) != settings.treeView {
            settings.treeView = group.isSelected(at: 1)
        }
        refresh(group)
    }

    @objc private func pauseToggled(_ group: NSToolbarItemGroup) {
        ProcessStore.shared.paused.toggle()
        refresh(group)
    }

    @objc private func groupActionChosen(_ group: NSToolbarItemGroup) {
        guard let actions = Self.groupActions[group.itemIdentifier]?.actions, actions.indices.contains(group.selectedIndex) else { return }
        actions[group.selectedIndex].perform()
    }

    @objc private func actionChosen(_ item: NSToolbarItem) {
        ToolbarAction(rawValue: item.tag)?.perform()
    }

    @objc private func elevate(_ sender: Any?) {
        let mode = Elevation.shared.mode
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
    }

    /// Opens the filters menu just under the toolbar, at the pointer.
    private func popUpFiltersMenu() {
        guard let window, let content = window.contentView else { return }
        let pointer = window.mouseLocationOutsideOfEventStream
        let origin = content.convert(NSPoint(x: pointer.x - 16, y: window.contentLayoutRect.maxY - 2), from: nil)
        FiltersMenuSource.makeMenu().popUp(positioning: nil, at: origin, in: content)
    }
}

/// The filters menu: the less common filters and the saved filters. Built each time it opens.
@MainActor
final class FiltersMenuSource: NSObject, NSMenuDelegate {
    static let shared = FiltersMenuSource()

    /// A menu that fills itself in when it is about to open, for a toolbar item that holds on to one.
    private(set) lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = Self.makeMenu()
        let items = fresh.items
        fresh.removeAllItems()
        menu.removeAllItems()
        items.forEach(menu.addItem)
    }

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
        if let key = ProcessSelection.shared.focused {
            let name = ProcessStore.shared.item(key)?.name ?? "Process"
            menu.add("Stop Focusing on \(name) (\(key.pid))", image: "viewfinder") { ProcessSelection.shared.focus(nil) }
        }
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
