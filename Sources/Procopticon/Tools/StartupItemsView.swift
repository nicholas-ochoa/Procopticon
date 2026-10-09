import AppKit
import ProcopticonCore
import SwiftUI

@MainActor
enum StartupItemsWindow {
    static func open() {
        WindowManager.shared.show(id: "startupItems", title: "Startup Items", size: NSSize(width: 1020, height: 600), autosave: "StartupItems") {
            StartupItemsView()
        }
    }
}

/// A category with its items, or one item.
final class StartupRow {
    let key: String
    let category: StartupItem.Category
    let item: StartupItem?
    let children: [StartupRow]

    init(category: StartupItem.Category, items: [StartupItem]) {
        key = "category:" + category.rawValue
        self.category = category
        item = nil
        children = items.map { StartupRow(item: $0) }
    }

    init(item: StartupItem) {
        key = item.id
        category = item.category
        self.item = item
        children = []
    }
}

/// Everything that starts code outside launchd's job list: login and background items, extensions,
/// cron, hooks and plug-ins, in an Autoruns-style tree.
struct StartupItemsView: View {
    @StateObject private var loader = PrivilegedLoader<StartupItemsReport>()
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("startupItemsHideApple") private var hideApple = true
    @State private var search = ""
    @State private var revision = 0

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Hide Apple items", isOn: $hideApple)
                    .toggleStyle(.checkbox)
                    .help("Hide items signed by Apple or in /System, so third-party ones stand out")
                if loader.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(rows.reduce(0) { $0 + $1.children.count }) items").foregroundStyle(.secondary)
                FilterField($search, width: 200)
                Button("Login Items Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("Open System Settings ▸ General ▸ Login Items & Extensions, where login and background items are turned on or off")
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Collect the items again")
            }
            .padding(8)
            Divider()
            if let warnings = loader.value?.warnings, !warnings.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if Elevation.shared.mode == .standard {
                        Button("Show Details for All Processes…") {
                            Task {
                                try? await Elevation.shared.startHelper()
                                load()
                            }
                        }
                        .controlSize(.small)
                        .help("Authorize once (administrator password) to read every user's items")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
            }
            OutlineTable(
                roots: rows,
                children: { $0.children },
                revision: revision &+ search.hashValue &+ (hideApple ? 1 : 0) &+ (settings.searchUsesRegex ? 2 : 0),
                columns: Self.columns,
                autosaveName: "StartupItemsTable",
                key: { AnyHashable($0.key) },
                rowStyle: { row in
                    row.item?.status.contains("not allowed") == true || row.item?.status == "Disabled"
                        ? RowStyle(background: NSColor.systemGray.withAlphaComponent(0.15)) : nil
                },
                menu: { menu(for: $0.compactMap(\.item)) },
                onDoubleClick: { row in
                    if let path = row.item?.path, FileManager.default.fileExists(atPath: path) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                },
                defaultSort: nil)
            Divider()
            Text("launchd agents and daemons, loaded or not, are listed in the Services tab. Double-click an item to reveal it in Finder.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { load() }
        .onReceive(loader.$value) { _ in revision &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: SigningCache.didUpdateNotification)) { _ in revision &+= 1 }
    }

    private func load() {
        loader.load(.startupItems) { if case .startupItems(let r) = $0 { return r } else { return nil } }
    }

    private var rows: [StartupRow] {
        let m = settings.matcher(search)
        let items = (loader.value?.items ?? []).filter { item in
            if hideApple, Self.isApple(item) { return false }
            return m.isEmpty || m.matchesAny(item.name, item.kind, item.path, item.identifier, item.developer, item.details, item.parent)
        }
        let grouped = Dictionary(grouping: items, by: \.category)
        return StartupItem.Category.allCases.compactMap { category in
            guard let list = grouped[category], !list.isEmpty else { return nil }
            return StartupRow(category: category, items: list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    /// Part of macOS: in /System, or signed by Apple.
    static func isApple(_ item: StartupItem) -> Bool {
        if let id = item.identifier, id.hasPrefix("com.apple.") { return true }
        guard let path = item.path else { return false }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") { return true }
        return signing(item)?.isAppleSigned == true
    }

    private static func signing(_ item: StartupItem) -> SigningInfo? {
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else { return nil }
        return SigningCache.shared.info(for: path)
    }

    private func menu(for items: [StartupItem]) -> NSMenu {
        let m = NSMenu()
        guard let first = items.first else { return m }
        if let path = first.path {
            m.add("Reveal in Finder", enabled: FileManager.default.fileExists(atPath: path)) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            m.add("Inspect Executable…", enabled: ProcessDetailsHelpers.isMachO(Bundle(path: path)?.executablePath ?? path)) {
                InspectorWindow.open(path: Bundle(path: path)?.executablePath ?? path)
            }
        }
        if let id = first.identifier, let service = ServiceStore.shared.items.first(where: { $0.label == id }) {
            m.add("Show Service") { ServicePropertiesWindow.open(service) }
        }
        if let id = first.identifier, let running = ProcessStore.shared.items.values.first(where: {
            !$0.isRemoved && ($0.bundleInfo?.bundleIdentifier == id || $0.record.path == first.path)
        }) {
            m.add("Show Process") { ProcessSelection.shared.reveal(pid: running.pid) }
        }
        m.addItem(.separator())
        m.add("Copy Path", enabled: first.path != nil) { ProcessActions.copy(items.compactMap(\.path).joined(separator: "\n")) }
        if first.identifier != nil {
            m.add("Copy Identifier") { ProcessActions.copy(items.compactMap(\.identifier).joined(separator: "\n")) }
        }
        return m
    }

    static let columns: [TableColumnSpec<StartupRow>] = {
        var name = TableColumnSpec<StartupRow>.string("name", "Name", width: 260, help: "The item, under the kind of startup it is") { row in
            row.item?.name ?? "\(row.category.rawValue) (\(row.children.count))"
        }
        name.image = { row in row.item?.path.map { ProcessIcons.icon(forPath: $0) } }
        name.tooltip = { row in row.item == nil ? row.category.help : row.item?.path }
        return [
            name,
            .string("kind", "Kind", width: 140, help: "What sort of item it is") { $0.item?.kind ?? "" },
            .string("status", "Status", width: 130,
                    help: "Enabled or disabled by its app; “not allowed” means it's turned off in Login Items & Extensions") { $0.item?.status ?? "" },
            .string("developer", "Developer", width: 150, help: "The developer named in Background Task Management, or the signer") { row in
                guard let item = row.item else { return "" }
                return item.developer ?? signing(item)?.organization ?? ""
            },
            .string("signature", "Signature", width: 130, visible: false, help: "Result of checking the item's code signature") { row in
                row.item.flatMap(signing)?.verificationSummary ?? ""
            },
            .string("team", "Team ID", width: 90, visible: false, help: "The developer's Team ID") { row in
                guard let item = row.item else { return "" }
                return item.teamIdentifier ?? signing(item)?.teamIdentifier ?? ""
            },
            .string("parent", "App", width: 130, help: "The app the item belongs to") { $0.item?.parent ?? "" },
            .string("user", "User", width: 80, help: "The user it's registered for; blank when it's for everyone") { $0.item?.user ?? "" },
            .string("path", "Path", width: 360, help: "The executable, bundle or script") { $0.item?.path ?? "" },
            .string("details", "Details", width: 300, help: "Schedule, property list, version or flags") { $0.item?.details ?? "" },
            .string("identifier", "Identifier", width: 200, visible: false, help: "Bundle identifier or launchd label") { $0.item?.identifier ?? "" },
            .number("lastUsed", "Last used", width: 140, visible: false, help: "When Background Task Management last saw the item run",
                    value: { $0.item?.lastUsed ?? .distantPast },
                    text: { $0.item?.lastUsed.map { Fmt.date($0.timeIntervalSince1970) } ?? "" }),
        ]
    }()
}
