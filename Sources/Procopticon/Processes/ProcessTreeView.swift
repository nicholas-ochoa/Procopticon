import AppKit
import Combine
import ProcopticonCore
import SwiftUI

/// Selection shared between the process list, the menu bar commands and the toolbar.
final class ProcessSelection: ObservableObject {
    static let shared = ProcessSelection()
    @Published var items: [ProcessItem] = []
    let table = OutlineTableController()
    private var followObserver: AnyCancellable?
    private var focusObserver: AnyCancellable?

    /// The process the list keeps in view, with its children, as it updates.
    @Published private(set) var followed: ProcessKey?

    /// Keeps `key` in view in place of any process kept in view before; nil stops.
    func follow(_ key: ProcessKey?) {
        followed = key
        table.followedKey = key.map(AnyHashable.init)
        // Stop following once the process exits.
        followObserver = key == nil ? nil : ProcessStore.shared.$revision.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let key = self.followed else { return }
            if ProcessStore.shared.item(key)?.isRemoved ?? true {
                self.follow(nil)
            }
        }
    }

    /// The process the list is narrowed to, with its descendants (see `ProcessFilterOptions.focus`).
    @Published private(set) var focused: ProcessKey?

    /// Narrows the list to `key` and its descendants in place of any process focused before; nil
    /// shows everything again.
    func focus(_ key: ProcessKey?) {
        if focused != key { focused = key }
        ProcessStore.shared.filter.focus = key
        // Stop focusing once the process has left the list (after it exits and is no longer shown).
        focusObserver = key == nil ? nil : ProcessStore.shared.$revision.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let key = self.focused else { return }
            if ProcessStore.shared.item(key) == nil {
                self.focus(nil)
            }
        }
    }

    func reveal(pid: Int32) {
        guard let item = ProcessStore.shared.item(pid: pid) else { return }
        NotificationCenter.default.post(name: .showTab, object: MainTab.processes)
        DispatchQueue.main.async {
            if !self.table.reveal(AnyHashable(item.key)) {
                // Filtered out: clear the search and focus, and try again.
                ProcessStore.shared.filter.text = ""
                self.focus(nil)
                DispatchQueue.main.async { self.table.reveal(AnyHashable(item.key)) }
            }
        }
    }
}

struct ProcessTreeView: View {
    var active = true
    @ObservedObject var store = ProcessStore.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var highlightRevision = 0
    private let columns = ProcessColumns.shared

    var body: some View {
        TableUnderToolbar { topInset in
            table(topInset: topInset)
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightsChanged)) { _ in highlightRevision &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: SigningCache.didUpdateNotification)) { _ in highlightRevision &+= 1 }
        .onReceive(ProcessSelection.shared.$followed.dropFirst()) { _ in highlightRevision &+= 1 }
    }

    private func table(topInset: CGFloat) -> some View {
        OutlineTable(
            roots: store.roots,
            children: { $0.children },
            revision: store.revision &+ highlightRevision,
            columns: columns,
            autosaveName: "ProcessTree",
            key: { AnyHashable($0.key) },
            rowStyle: { Highlighter.style(for: $0, followed: ProcessSelection.shared.followed) },
            menu: { ProcessMenu.build(for: $0, shortcuts: true) },
            onDoubleClick: { PropertiesWindow.open($0) },
            onSelectionChange: { ProcessSelection.shared.items = $0 },
            onDeleteKey: { ProcessActions.terminate($0) },
            controller: ProcessSelection.shared.table,
            font: settings.processListFont,
            isActive: active,
            topInset: topInset
        )
    }
}

@MainActor
enum ProcessMenu {
    /// `shortcuts` shows the menu bar's shortcuts for the same commands. They act on the process
    /// list's selection, so only its menu shows them; other tables of processes leave them off.
    static func build(for items: [ProcessItem], shortcuts: Bool = false) -> NSMenu {
        let menu = NSMenu()
        populate(menu, items: items, shortcuts: shortcuts)
        return menu
    }

    static func populate(_ menu: NSMenu, items: [ProcessItem], shortcuts: Bool = false) {
        let live = items.filter { !$0.isRemoved }
        guard let first = live.first else { return }
        let single = live.count == 1
        func shortcut(_ item: NSMenuItem, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
            guard shortcuts else { return }
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
        }
        let delete = String(UnicodeScalar(UInt8(NSBackspaceCharacter)))

        shortcut(menu.add("Terminate", image: "xmark.circle") { ProcessActions.terminate(live) }, delete, .command)
        shortcut(menu.add("Terminate Tree", image: "xmark.square") { ProcessActions.terminateTree(live) }, delete, [.command, .shift])
        shortcut(menu.add("Force Kill", image: "bolt.circle") { ProcessActions.forceKill(live) }, delete, [.command, .option])
        if live.contains(where: { $0.record.isStopped }) {
            menu.add("Resume", image: "play.circle") { ProcessActions.resume(live) }
            menu.add("Resume Tree") { ProcessActions.resumeTree(live) }
        }
        if live.contains(where: { !$0.record.isStopped }) {
            menu.add("Suspend", image: "pause.circle") { ProcessActions.suspend(live) }
            menu.add("Suspend Tree") { ProcessActions.suspendTree(live) }
        }
        if single {
            menu.add("Restart", image: "arrow.clockwise.circle") { ProcessActions.restart(first) }
        }
        menu.submenu("Send Signal", image: "antenna.radiowaves.left.and.right") { sub in
            for (sig, title) in ProcessActions.signals {
                sub.add(title) { ProcessActions.signal(live, sig, verb: "Send Signal", explanation: "\(title) will be sent.") }
            }
            sub.addItem(.separator())
            sub.add("Other Signal…") { ProcessActions.customSignal(live) }
        }
        menu.submenu("Priority", image: "gauge.with.dots.needle.33percent") { sub in
            for (value, title) in ProcessActions.priorities {
                sub.add(title, state: single && first.record.nice == value ? .on : .off) { ProcessActions.setNice(live, value) }
            }
            sub.addItem(.separator())
            sub.add("Background (throttle CPU and I/O)") { ProcessActions.setBackground(live, true) }
            sub.add("Foreground (remove throttling)") { ProcessActions.setBackground(live, false) }
        }
        menu.addItem(.separator())

        if single {
            if ProcessActions.isApplication(first) {
                menu.add("Bring to Front", image: "macwindow") { ProcessActions.bringToFront(first) }
                menu.add("Quit Application", image: "power") { ProcessActions.quitApplication(first) }
                menu.addItem(.separator())
            }
            menu.submenu("Diagnostics", image: "stethoscope") { sub in
                sub.add("Sample Process…") { ProcessActions.sample(first) }
                sub.add("Spindump…") { ProcessActions.spindump(first) }
                sub.addItem(.separator())
                sub.add("Virtual Memory Map…") { ProcessActions.vmmap(first, summary: false) }
                sub.add("Virtual Memory Summary…") { ProcessActions.vmmap(first, summary: true) }
                sub.add("Memory Footprint…") { ProcessActions.footprint(first) }
                sub.add("Heap Summary…") { ProcessActions.heap(first) }
                sub.add("Find Leaks…") { ProcessActions.leaks(first) }
                sub.addItem(.separator())
                sub.add("Open Files (lsof)…") { ProcessActions.openFiles(first) }
                sub.add("File Activity…") { PropertiesWindow.open(first, tab: .fileActivity) }
                sub.add("Create Core Dump…") { ProcessActions.createCoreDump(first) }
            }
            menu.addItem(.separator())
            shortcut(menu.add("Reveal in Finder", enabled: first.record.path != nil, image: "folder") { ProcessActions.revealInFinder(first) },
                     "r", [.command, .shift])
            if BundleInfoCache.outermostApplicationPath(first.record.path ?? "") != nil {
                menu.add("Reveal Application in Finder") { ProcessActions.revealBundle(first) }
            }
            menu.add("Inspect Executable…", enabled: first.record.path != nil, image: "doc.text.magnifyingglass") {
                if let path = first.record.path { InspectorWindow.open(path: path) }
            }
            menu.add("Search Online", image: "magnifyingglass") { ProcessActions.searchOnline(first) }
            menu.submenu("Copy", image: "doc.on.doc") { sub in
                sub.add("Name") { ProcessActions.copy(first.name) }
                sub.add("PID") { ProcessActions.copy("\(first.pid)") }
                if let p = first.record.path { sub.add("Path") { ProcessActions.copy(p) } }
                if let c = first.record.commandLine { sub.add("Command Line") { ProcessActions.copy(c) } }
                if let b = first.bundleInfo?.bundleIdentifier { sub.add("Bundle Identifier") { ProcessActions.copy(b) } }
            }
            // The real parent; the tree may show the process under its responsible process instead.
            if first.record.ppid != first.pid, let parent = ProcessStore.shared.item(pid: first.record.ppid) {
                menu.add("Go to Parent (\(parent.name))") { ProcessSelection.shared.reveal(pid: parent.pid) }
            }
            if let r = first.record.responsiblePid, r != first.pid, let rp = ProcessStore.shared.item(pid: r) {
                menu.add("Go to Responsible Process (\(rp.name))") { ProcessSelection.shared.reveal(pid: r) }
            }
            // Only the process list scrolls to follow a process, or narrows to one.
            if shortcuts {
                let following = ProcessSelection.shared.followed == first.key
                menu.add("Keep in View", state: following ? .on : .off, image: "scope") {
                    ProcessSelection.shared.follow(following ? nil : first.key)
                }
                let focusing = ProcessSelection.shared.focused == first.key
                menu.add("Focus", state: focusing ? .on : .off, image: "viewfinder") {
                    ProcessSelection.shared.focus(focusing ? nil : first.key)
                }
            }
            menu.addItem(.separator())
            let props = menu.add("Properties", image: "info.circle") { PropertiesWindow.open(first) }
            props.keyEquivalent = "\r"
            props.keyEquivalentModifierMask = []
        }
    }
}

@MainActor
enum PropertiesWindow {
    static let widthKey = "propertiesWindowWidth"
    static let defaultWidth: Double = 820

    static func open(_ item: ProcessItem, tab: ProcessPropertiesView.PropertyTab = .general) {
        let key = item.key
        let saved = UserDefaults.standard.double(forKey: widthKey)
        WindowManager.shared.show(id: "props-\(key)", title: "\(item.displayName) (\(item.pid)) Properties",
                                  size: NSSize(width: saved > 0 ? saved : defaultWidth, height: 620), fullSizeContent: true) {
            ProcessPropertiesView(key: key, tab: tab)
        }
    }
}
