import AppKit
import Combine
import InformerCore
import SwiftUI

/// Selection shared between the process list, the menu bar commands and the toolbar.
final class ProcessSelection: ObservableObject {
    static let shared = ProcessSelection()
    @Published var items: [ProcessItem] = []
    let table = OutlineTableController()

    func reveal(pid: Int32) {
        guard let item = ProcessStore.shared.item(pid: pid) else { return }
        NotificationCenter.default.post(name: .showTab, object: MainTab.processes)
        DispatchQueue.main.async {
            if !self.table.reveal(AnyHashable(item.key)) {
                // Filtered out: clear the search and try again.
                ProcessStore.shared.filter.text = ""
                DispatchQueue.main.async { self.table.reveal(AnyHashable(item.key)) }
            }
        }
    }
}

struct ProcessTreeView: View {
    @ObservedObject var store = ProcessStore.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var highlightRevision = 0
    private let columns = ProcessColumns.shared

    var body: some View {
        OutlineTable(
            roots: store.roots,
            children: { $0.children },
            revision: store.revision &+ highlightRevision,
            columns: columns,
            autosaveName: "ProcessTree",
            key: { AnyHashable($0.key) },
            rowStyle: { Highlighter.style(for: $0) },
            menu: { ProcessMenu.build(for: $0) },
            onDoubleClick: { PropertiesWindow.open($0) },
            onSelectionChange: { ProcessSelection.shared.items = $0 },
            onDeleteKey: { ProcessActions.terminate($0) },
            controller: ProcessSelection.shared.table,
            font: settings.processListFont
        )
        .onReceive(NotificationCenter.default.publisher(for: .highlightsChanged)) { _ in highlightRevision &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: SigningCache.didUpdateNotification)) { _ in highlightRevision &+= 1 }
    }
}

@MainActor
enum ProcessMenu {
    static func build(for items: [ProcessItem]) -> NSMenu {
        let menu = NSMenu()
        populate(menu, items: items)
        return menu
    }

    static func populate(_ menu: NSMenu, items: [ProcessItem]) {
        let live = items.filter { !$0.isRemoved }
        guard let first = live.first else { return }
        let single = live.count == 1

        menu.add("Terminate", image: "xmark.circle") { ProcessActions.terminate(live) }
        menu.add("Terminate Tree", image: "xmark.square") { ProcessActions.terminateTree(live) }
        menu.add("Force Kill", image: "bolt.circle") { ProcessActions.forceKill(live) }
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
                sub.add("Create Core Dump…") { ProcessActions.createCoreDump(first) }
            }
            menu.addItem(.separator())
            menu.add("Reveal in Finder", enabled: first.record.path != nil, image: "folder") { ProcessActions.revealInFinder(first) }
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
            if let parent = first.parent {
                menu.add("Go to Parent (\(parent.name))") { ProcessSelection.shared.reveal(pid: parent.pid) }
            }
            if let r = first.record.responsiblePid, r != first.pid, let rp = ProcessStore.shared.item(pid: r) {
                menu.add("Go to Responsible Process (\(rp.name))") { ProcessSelection.shared.reveal(pid: r) }
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
    static func open(_ item: ProcessItem) {
        let key = item.key
        WindowManager.shared.show(id: "props-\(key)", title: "\(item.name) (\(item.pid)) Properties", size: NSSize(width: 760, height: 620)) {
            ProcessPropertiesView(key: key)
        }
    }
}
