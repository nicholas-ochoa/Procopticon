import AppKit
import CoreGraphics
import ProcopticonCore
import SwiftUI

// MARK: - Event log

@MainActor
enum EventLogWindow {
    static func open() {
        WindowManager.shared.show(id: "log", title: "Event Log", size: NSSize(width: 820, height: 480), autosave: "EventLog") {
            EventLogView()
        }
    }
}

struct EventLogView: View {
    @ObservedObject private var log = EventLog.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Record events", isOn: $log.enabled).toggleStyle(.checkbox)
                Spacer()
                FilterField($search, width: 240)
                Button("Copy") {
                    ProcessActions.copy(rows.map { "\(Fmt.date($0.date.timeIntervalSince1970))\t\($0.kind.rawValue)\t\($0.message)" }.joined(separator: "\n"))
                }
                .help("Copy the events shown (after filtering) as tab-separated text")
                Button("Clear") { log.clear() }
                    .help("Remove all recorded events")
            }
            .padding(8)
            Divider()
            OutlineTable(
                roots: rows,
                children: nil,
                revision: log.entries.count &+ (log.entries.last?.id ?? 0) &+ search.hashValue &+ (settings.searchUsesRegex ? 1 : 0),
                columns: [
                    .number("time", "Time", width: 150,
                            help: "When the event happened",
                            value: { $0.date }, text: { Fmt.date($0.date.timeIntervalSince1970) }),
                    .string("kind", "Event", width: 120, help: "The kind of event") { $0.kind.rawValue },
                    .string("message", "Details", width: 520, help: "What happened") { $0.message },
                ],
                autosaveName: "EventLogTable",
                key: { AnyHashable($0.id) },
                rowStyle: { e in
                    let h = AppSettings.shared.highlights
                    switch e.kind {
                    case .processStarted, .serviceStarted: return h[.new].map { RowStyle(background: $0.color.withAlphaComponent(0.18)) }
                    case .processExited, .serviceStopped: return h[.removed].map { RowStyle(background: $0.color.withAlphaComponent(0.18)) }
                    default: return nil
                    }
                },
                onDoubleClick: { e in if let pid = e.pid { ProcessSelection.shared.reveal(pid: pid) } },
                defaultSort: (column: "time", ascending: false))
        }
    }

    private var rows: [EventLog.Entry] {
        let m = settings.matcher(search)
        guard !m.isEmpty else { return log.entries }
        return log.entries.filter { m.matchesAny($0.message, $0.kind.rawValue) }
    }
}

// MARK: - Find process by window

@MainActor
enum WindowFinder {
    static func open() {
        WindowManager.shared.show(id: "windows", title: "Find Process by Window", size: NSSize(width: 820, height: 480)) {
            WindowListView()
        }
    }
}

struct WindowListView: View {
    struct Row: Hashable {
        var id: Int
        var pid: Int32
        var owner: String
        var title: String
        var layer: Int
        var bounds: String
        var onScreen: Bool
    }

    @State private var rows: [Row] = []
    @State private var onScreenOnly = true
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Windows currently known to the window server. Double-click to select the owning process.")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("On-screen only", isOn: $onScreenOnly).toggleStyle(.checkbox)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload the window list")
            }
            .padding(8)
            Divider()
            OutlineTable(
                roots: rows,
                children: nil,
                revision: revision,
                columns: Self.columns,
                autosaveName: "WindowList",
                key: { AnyHashable($0.id) },
                menu: { sel in
                    let m = NSMenu()
                    if let r = sel.first {
                        m.add("Go to Process") { ProcessSelection.shared.reveal(pid: r.pid) }
                        if let p = ProcessStore.shared.item(pid: r.pid) {
                            m.add("Process Properties") { PropertiesWindow.open(p) }
                            m.add("Bring to Front") { ProcessActions.bringToFront(p) }
                        }
                    }
                    return m
                },
                onDoubleClick: { ProcessSelection.shared.reveal(pid: $0.pid) },
                defaultSort: (column: "layer", ascending: true))
        }
        .task { load() }
        .onChange(of: onScreenOnly) { load() }
    }

    private func load() {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        rows = list.compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? Int, let pid = w[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return Row(id: id, pid: pid, owner: w[kCGWindowOwnerName as String] as? String ?? "",
                       title: w[kCGWindowName as String] as? String ?? "",
                       layer: w[kCGWindowLayer as String] as? Int ?? 0,
                       bounds: "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0))  \(Int(b["Width"] ?? 0))×\(Int(b["Height"] ?? 0))",
                       onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        revision &+= 1
    }

    static let columns: [TableColumnSpec<Row>] = {
        var owner = TableColumnSpec<Row>.string("owner", "Process", width: 180, help: "The app or process that owns the window") { $0.owner }
        owner.image = { r in ProcessStore.shared.item(pid: r.pid).map { ProcessIcons.icon(for: $0.record) } ?? ProcessIcons.executable }
        return [
            owner,
            .number("pid", "PID", width: 60, help: "Process ID of the owner", value: { $0.pid }, text: { "\($0.pid)" }),
            .string("title", "Title", width: 280, help: "The window's title; other apps' titles need Screen Recording permission") { $0.title },
            .number("layer", "Layer", width: 60,
                    help: "Window layer: 0 for normal windows; higher layers (panels, menus, overlays) sit above them",
                    value: { $0.layer }, text: { "\($0.layer)" }),
            .string("bounds", "Bounds", width: 160, help: "Position and size on screen, in points: x,y  width×height") { $0.bounds },
            .number("id", "Window ID", width: 80, help: "The window server's number for the window", value: { $0.id }, text: { "\($0.id)" }),
        ]
    }()
}
