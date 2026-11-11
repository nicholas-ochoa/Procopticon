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
    @State private var working = false

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
                    row.item?.isEnabled == false || row.item?.status.contains("not allowed") == true
                        ? RowStyle(background: NSColor.systemGray.withAlphaComponent(0.15)) : nil
                },
                menu: { menu(for: $0.compactMap(\.item)) },
                onDoubleClick: { row in
                    if let path = row.item?.path, FileManager.default.fileExists(atPath: path) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                },
                onDeleteKey: { rows in remove(rows.compactMap(\.item)) },
                defaultSort: nil)
            Divider()
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                Text("Right-click items to disable, enable or remove them. launchd agents and daemons are also in the Services tab.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .onAppear { load() }
        .onReceive(loader.$value) { _ in revision &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: SigningCache.didUpdateNotification)) { _ in revision &+= 1 }
    }

    private func load() {
        loader.load(.startupItems) { response in
            guard case .startupItems(var report) = response else { return nil }
            // App extension choices and Open at Login are per user, so they're read here, as the user.
            StartupItems.applyAppExtensionElections(&report.items)
            StartupItems.addOpenAtLoginItems(&report.items)
            return report
        }
    }

    // MARK: Changing items

    private func setEnabled(_ items: [StartupItem], _ on: Bool) {
        let targets = items.filter { $0.toggle != nil && ($0.isEnabled ?? true) != on }
        guard !targets.isEmpty else { return }
        if !on {
            let system = targets.filter { if case .launchd(let domain, _)? = $0.toggle { return domain == "system" } else { return false } }
            if !system.isEmpty, !Alerts.confirm("Disable \(Self.names(system))?",
                                               message: "System daemons can be part of other software's normal operation (a VPN, a backup, a driver). Disabling one keeps it from starting at the next restart; Enable undoes it.",
                                               button: "Disable", destructive: false, kind: "Disable Startup Item") {
                return
            }
        }
        run(targets.compactMap { item in item.toggle.map { (item, StartupAction.setEnabled($0, on)) } },
            verb: on ? "Enabled" : "Disabled")
    }

    private func remove(_ items: [StartupItem]) {
        let targets = items.filter { $0.removal != nil }
        guard !targets.isEmpty else { return }
        let effects = targets.compactMap { item -> String? in
            switch item.removal {
            case .launchdPlist(_, _, let plist)?: return "• \(item.name): unloads it and moves \(plist) to the Trash"
            case .cron?: return "• \(item.name): deletes the line from the crontab"
            case .trash(let path)?: return "• \(item.name): moves \(path) to the Trash"
            case .hook(_, let key)?: return "• \(item.name): deletes the \(key) setting (the script itself stays)"
            case .profile?: return "• \(item.name): removes the configuration profile"
            case .openAtLogin?: return "• \(item.name): takes it off Open at Login (the app stays)"
            case nil: return nil
            }
        }
        let skipped = items.count - targets.count
        guard Alerts.confirm("Remove \(Self.names(targets))?",
                             message: effects.joined(separator: "\n")
                                + (skipped > 0 ? "\n\n\(skipped) of the selected items can't be removed here; their own app or System Settings removes them." : ""),
                             button: "Remove", suppressible: false) else { return }
        run(targets.compactMap { item in item.removal.map { (item, StartupAction.remove($0)) } }, verb: "Removed")
    }

    private static func names(_ items: [StartupItem]) -> String {
        items.count == 1 ? "“\(items[0].name)”" : "\(items.count) startup items"
    }

    /// Runs the actions one by one: as the user when they're the user's own, otherwise through the
    /// helper (asking to elevate once if needed). Reloads the list afterwards.
    private func run(_ actions: [(StartupItem, StartupAction)], verb: String) {
        // The menu is disabled meanwhile; the Delete key isn't. Two batches at once could each
        // rewrite the crontab from the same starting point, and one edit would be lost.
        guard !working else { return }
        working = true
        Task { @MainActor in
            var failures: [String] = []
            for (item, action) in actions {
                let request = PrivilegedRequest.startupAction(action)
                var response: PrivilegedResponse
                if StartupItems.runsAsUser(action) {
                    response = await Task.detached { Elevation.shared.performLocally(request) }.value
                    // An extension's setting belongs to the user; anything else may still need root.
                    var userOnly = false
                    switch action {
                    case .setEnabled(.appExtension, _), .setEnabled(.openAtLogin, _), .remove(.openAtLogin): userOnly = true
                    default: break
                    }
                    if response.error?.isPermissionDenied == true, !userOnly {
                        response = await Elevation.shared.performElevated(request, requiresRoot: true)
                    }
                } else {
                    response = await Elevation.shared.performElevated(request, requiresRoot: true)
                }
                if let e = response.error {
                    if e == .cancelled { break }
                    failures.append("\(item.name): \(e.message)")
                } else {
                    EventLog.shared.add(.action, "\(verb) startup item \(item.name) (\(item.kind))")
                }
            }
            working = false
            load()
            if !failures.isEmpty {
                Alerts.error("Some startup items couldn't be changed", failures.joined(separator: "\n"))
            }
        }
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
        if items.contains(where: { $0.toggle != nil && $0.isEnabled != false }) {
            m.add("Disable", enabled: !working, image: "pause.circle") { setEnabled(items, false) }.toolTip =
                "Keep the items from starting: launchd jobs are disabled, app extensions turned off, Open at Login apps taken off the list (and remembered here), cron jobs commented out, periodic scripts made non-executable. What's running keeps running until it quits or you log out"
        }
        if items.contains(where: { $0.toggle != nil && $0.isEnabled == false }) {
            m.add("Enable", enabled: !working, image: "play.circle") { setEnabled(items, true) }.toolTip =
                "Let the items start again. Items turned off in Login Items settings (“not allowed”) also need turning on there"
        }
        if items.contains(where: { $0.removal != nil }) {
            m.add("Remove…", enabled: !working, image: "trash") { remove(items) }.toolTip =
                "Remove the items: launchd property lists, plug-ins and scripts go to the Trash, cron jobs and login hooks are deleted, Open at Login apps taken off the list, profiles removed (⌫)"
        }
        if m.numberOfItems > 0 {
            m.addItem(.separator())
        }
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
