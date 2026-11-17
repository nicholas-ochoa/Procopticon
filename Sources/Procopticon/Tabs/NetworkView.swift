import AppKit
import ProcopticonCore
import SwiftUI

struct NetworkView: View {
    @ObservedObject private var store = NetworkStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Binding var search: String
    var active = true
    @State private var hideListening = false
    @State private var hideLoopback = false
    @State private var protocolFilter = "All"
    @AppStorage("NetworkTable.groupByProcess") private var groupByProcess = true

    var body: some View {
        let items = filtered
        return TableUnderToolbar {
            FilterBar {
                Text("Protocol").foregroundStyle(.secondary).fixedSize()
                Picker(selection: $protocolFilter) {
                    ForEach(["All", "TCP", "UDP"], id: \.self) { Text($0).tag($0) }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Protocol")
                Toggle("Group by process", isOn: $groupByProcess).toggleStyle(.checkbox).fixedSize()
                    .help("List each process once, with its connections under it and those to the same place on one row")
                Toggle("Hide listening", isOn: $hideListening).toggleStyle(.checkbox).fixedSize()
                Toggle("Hide loopback", isOn: $hideLoopback).toggleStyle(.checkbox).fixedSize()
                Toggle("Resolve addresses", isOn: $settings.resolveAddresses).toggleStyle(.checkbox).fixedSize()
            } trailing: {
                if Elevation.shared.mode == .standard {
                    Image(systemName: "lock").foregroundStyle(.secondary).help("Showing your processes only — authorize to see all connections")
                }
                Text("\(items.count) connections").foregroundStyle(.secondary).lineLimit(1)
            }
        } table: { topInset in
            OutlineTable(
                roots: groupByProcess ? NetworkRow.grouped(items, isNew: store.isNew) : NetworkRow.list(items),
                children: groupByProcess ? { $0.children } : nil,
                revision: store.revision &+ search.hashValue &+ (settings.searchUsesRegex ? 4 : 0) &+ protocolFilter.hashValue &+ (hideListening ? 1 : 0) &+ (hideLoopback ? 2 : 0),
                columns: groupByProcess ? Self.treeColumns : Self.listColumns,
                // Each has its own column layout: the tree's first column is far wider, and it
                // has no use for the Remote column that the list can't do without.
                autosaveName: groupByProcess ? "NetworkTree" : "NetworkList",
                key: { $0.key },
                rowStyle: { style($0) },
                menu: { menu($0) },
                onDoubleClick: { row in
                    if let p = ProcessStore.shared.item(pid: row.pid) { PropertiesWindow.open(p) }
                },
                defaultSort: (column: "process", ascending: true),
                isActive: active,
                topInset: topInset)
                // A list and a tree are different tables: start over rather than turn one into the other.
                .id(groupByProcess)
        }
        .task(id: active) {
            // Enumerate sockets only while this tab is visible.
            guard active else { return }
            store.retain(interval: max(1, settings.refreshInterval))
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                }
            } onCancel: {
                Task { @MainActor in NetworkStore.shared.release() }
            }
        }
    }

    private var filtered: [ConnectionItem] {
        let m = settings.matcher(search)
        return store.items.filter { item in
            let e = item.connection.endpoint
            switch protocolFilter {
            case "TCP": if e.proto != IPPROTO_TCP { return false }
            case "UDP": if e.proto != IPPROTO_UDP { return false }
            default: break
            }
            if hideListening, e.isListening || (e.proto == IPPROTO_UDP && e.remotePort == 0) { return false }
            if hideLoopback, HostNames.isLoopback(e.localAddress), HostNames.isLoopback(e.remoteAddress) || e.remoteAddress == "*" {
                return false
            }
            if m.isEmpty { return true }
            return m.matchesAny(item.connection.processName, e.localAddress, e.remoteAddress, item.remoteHost, item.remoteService)
                || m.matchesIdentifier("\(e.localPort)") || m.matchesIdentifier("\(e.remotePort)")
                || m.matchesIdentifier("\(item.connection.pid)")
        }
        .sorted(by: NetworkRow.inDisplayOrder)
    }

    private func style(_ row: NetworkRow) -> RowStyle? {
        // A row of several sockets has them all in the same phase (see `NetworkRow.grouped`).
        guard let c = row.entry?.first else { return nil }
        let h = AppSettings.shared.highlights
        if c.removedAt != nil, let s = h[.removed], s.enabled { return RowStyle(background: s.color.withAlphaComponent(0.5)) }
        if store.isNew(c), let s = h[.new], s.enabled { return RowStyle(background: s.color.withAlphaComponent(0.5)) }
        return nil
    }

    private func menu(_ rows: [NetworkRow]) -> NSMenu {
        let m = NSMenu()
        guard let row = rows.first else { return m }
        let pid = row.pid
        m.add("Go to Process", image: "arrow.right.circle") { ProcessSelection.shared.reveal(pid: pid) }
        if let p = ProcessStore.shared.item(pid: pid) {
            m.add("Process Properties") { PropertiesWindow.open(p) }
            m.add("Terminate Process") { ProcessActions.terminate([p]) }
        }
        let remote = row.entry?.endpoint.remoteAddress ?? ""
        if remote != "*", !remote.isEmpty {
            m.addItem(.separator())
            m.add("Look Up Remote Address (whois)…") {
                Reports.show(title: "whois \(remote)") {
                    ToolRunner.run("/usr/bin/whois", [remote], timeout: 30).combined
                }
            }
            m.add("Copy Remote Address") { ProcessActions.copy(remote) }
        }
        return m
    }

    /// A column of text about a connection, blank in a process's row. `styled` colors it. A row of
    /// several sockets lists what they don't have in common.
    private static func text(_ id: String, _ title: String, width: CGFloat, help: String,
                             styled: ((ConnectionItem) -> NSAttributedString)? = nil,
                             _ text: @escaping (ConnectionItem) -> String) -> TableColumnSpec<NetworkRow> {
        var spec = TableColumnSpec<NetworkRow>.string(id, title, width: width, visible: false, help: help) { row in
            guard let entry = row.entry else { return "" }
            if entry.items.count == 1 { return text(entry.first) }
            return ConnectionStyle.joined(entry.items.map { NSAttributedString(string: text($0)) }).string
        }
        if let styled {
            spec.attributedText = { row in
                guard let entry = row.entry else { return NSAttributedString() }
                return entry.items.count == 1 ? styled(entry.first) : ConnectionStyle.joined(entry.items.map(styled))
            }
        }
        return spec
    }

    /// A column of a number about a connection, blank in a process's row. `styled` colors it. A row
    /// of several sockets lists their numbers, and sorts by the first.
    private static func number<V: Comparable & ExpressibleByIntegerLiteral>(
        _ id: String, _ title: String, width: CGFloat, help: String,
        styled: ((ConnectionItem) -> NSAttributedString)? = nil,
        value: @escaping (ConnectionItem) -> V, text: @escaping (ConnectionItem) -> String) -> TableColumnSpec<NetworkRow> {
        let listed: (NetworkEntry) -> String = { entry in
            if entry.items.count == 1 { return text(entry.first) }
            return ConnectionStyle.joined(entry.items.map { NSAttributedString(string: text($0)) }).string
        }
        var spec = TableColumnSpec<NetworkRow>.number(id, title, width: width, visible: false, help: help,
                                                      value: { $0.entry.map { value($0.first) } ?? 0 }, text: { $0.entry.map(listed) ?? "" })
        spec.exportValue = { row in
            guard let entry = row.entry else { return .null }
            return entry.items.count == 1 ? ExportValue(value(entry.first), text: text(entry.first)) : .string(listed(entry))
        }
        if let styled {
            spec.attributedText = { row in
                guard let entry = row.entry else { return NSAttributedString() }
                return entry.items.count == 1 ? styled(entry.first) : ConnectionStyle.joined(entry.items.map(styled))
            }
        }
        return spec
    }

    static let treeColumns = columns(grouped: true)
    static let listColumns = columns(grouped: false)

    /// The two ends of a connection are each written in one column, address and port together, and
    /// under its process a connection's row is named for its far end. The columns for the parts on
    /// their own are there to sort by, hidden until asked for.
    private static func columns(grouped: Bool) -> [TableColumnSpec<NetworkRow>] {
        var process = TableColumnSpec<NetworkRow>("process", "Name", width: grouped ? 340 : 180,
                                                  help: grouped ? "The process, and under it what each of its sockets is connected to or listens on"
                                                      : "The process the socket belongs to",
                                                  text: { row in
            if case .connection(let entry, true) = row { return ConnectionStyle.label(entry).string }
            return row.processName
        }, less: { a, b in
            // Under a process: what it listens on, then what it's connected to.
            if case .connection(let x, true) = a, case .connection(let y, true) = b {
                return NetworkRow.inDisplayOrder(x.first, y.first)
            }
            return a.processName.localizedStandardCompare(b.processName) == .orderedAscending
        })
        process.image = { row in
            if row.isNested { return nil }
            if let p = ProcessStore.shared.item(pid: row.pid) { return ProcessIcons.icon(for: p.record) }
            return ProcessIcons.executable
        }
        process.attributedText = { row in
            switch row {
            case .process(let group): ConnectionStyle.group(group)
            case .connection(let entry, true): ConnectionStyle.label(entry)
            case .connection(let entry, false): NSAttributedString(string: entry.first.connection.processName)
            }
        }
        process.tooltip = { row in
            if case .connection(let entry, true) = row { return ConnectionStyle.summary(entry) }
            return nil
        }
        process.monospacedDigits = false

        // Blank under the process's row, which has it; copying and exporting still include it.
        var pid = TableColumnSpec<NetworkRow>.number("pid", "PID", width: 60, help: "Process ID", value: { $0.pid }, text: { "\($0.pid)" })
        pid.attributedText = { $0.isNested ? NSAttributedString() : NSAttributedString(string: "\($0.pid)") }

        var proto = text("proto", "Protocol", width: 60, help: "TCP or UDP; TCP6 and UDP6 are IPv6") { $0.connection.endpoint.protocolName }
        proto.defaultVisible = true

        var remote = TableColumnSpec<NetworkRow>(
            "remote", "Remote", width: 300, visible: !grouped,
            help: "The far end: its host name where one is known, or its address, then the port and the service registered "
                + "for that port number",
            text: { $0.entry.map { ConnectionStyle.remote($0.first).string } ?? "" },
            less: { a, b in
                guard let x = a.entry, let y = b.entry else { return false }
                let e = x.endpoint, f = y.endpoint
                let name = x.first.remoteHost.isEmpty ? e.remoteAddress : x.first.remoteHost
                let other = y.first.remoteHost.isEmpty ? f.remoteAddress : y.first.remoteHost
                let order = e.hasPeer && f.hasPeer ? name.compare(other, options: [.numeric, .caseInsensitive]) : .orderedSame
                if order != .orderedSame { return order == .orderedAscending }
                return (e.hasPeer ? 1 : 0, e.remotePort) < (f.hasPeer ? 1 : 0, f.remotePort)
            })
        remote.attributedText = { $0.entry.map { ConnectionStyle.remote($0.first) } ?? NSAttributedString() }

        var local = TableColumnSpec<NetworkRow>(
            "local", "Local", width: 150,
            help: "The near end: the port alone for a connection, and the address too for a socket that listens "
                + "(* is every address of this Mac)",
            text: { $0.entry.map(ConnectionStyle.localText) ?? "" },
            less: { a, b in
                guard let e = a.entry?.endpoint, let f = b.entry?.endpoint else { return false }
                return (e.localPort, e.localAddress) < (f.localPort, f.localAddress)
            })
        local.attributedText = { $0.entry.map(ConnectionStyle.local) ?? NSAttributedString() }

        var state = text("state", "State", width: 90,
                         help: "TCP connection state, such as Listen or Established (blank for UDP)",
                         styled: { ConnectionStyle.state($0.connection.endpoint) }) { $0.connection.endpoint.stateName }
        state.defaultVisible = true

        return [
            process,
            pid,
            proto,
            remote,
            local,
            state,
            text("laddr", "Local address", width: 150, help: "Local IP address (* means any)",
                 styled: { ConnectionStyle.address($0.connection.endpoint.localAddress) }) { $0.connection.endpoint.localAddress },
            number("lport", "Local port", width: 70, help: "Local port", styled: { ConnectionStyle.port($0.connection.endpoint.localPort) },
                   value: { $0.connection.endpoint.localPort }, text: { p in
                let e = p.connection.endpoint
                return e.localPort == 0 ? "" : "\(e.localPort)"
            }),
            text("lhost", "Local host", width: 120, help: "Local address resolved to a host name",
                 styled: { ConnectionStyle.host($0.localHost, address: $0.connection.endpoint.localAddress) }) { $0.localHost },
            text("lservice", "Local service", width: 90,
                 help: "The service registered for the local port number (from /etc/services)") { $0.localService },
            text("raddr", "Remote address", width: 150, help: "Remote IP address",
                 styled: { ConnectionStyle.address($0.connection.endpoint.remoteAddress == "*" ? "" : $0.connection.endpoint.remoteAddress) }) {
                $0.connection.endpoint.remoteAddress == "*" ? "" : $0.connection.endpoint.remoteAddress
            },
            number("rport", "Remote port", width: 75, help: "Remote port", styled: { ConnectionStyle.port($0.connection.endpoint.remotePort) },
                   value: { $0.connection.endpoint.remotePort }, text: { p in
                let e = p.connection.endpoint
                return e.remotePort == 0 ? "" : "\(e.remotePort)"
            }),
            text("rhost", "Remote host", width: 200,
                 help: "Remote address resolved to a host name, when that's turned on in Settings",
                 styled: { ConnectionStyle.host($0.remoteHost, address: $0.connection.endpoint.remoteAddress) }) { $0.remoteHost },
            text("rservice", "Remote service", width: 90,
                 help: "The service registered for the remote port number (from /etc/services), such as https for 443. "
                     + "It's looked up from the number alone, so it's what the port is usually for") { $0.remoteService },
            number("sendq", "Send queue", width: 70,
                   help: "Bytes waiting in the socket's send buffer",
                   styled: { ConnectionStyle.queue($0.connection.endpoint.sendQueue) },
                   value: { $0.connection.endpoint.sendQueue }, text: { "\($0.connection.endpoint.sendQueue)" }),
            number("recvq", "Receive queue", width: 70,
                   help: "Bytes received but not yet read by the process",
                   styled: { ConnectionStyle.queue($0.connection.endpoint.recvQueue) },
                   value: { $0.connection.endpoint.recvQueue }, text: { "\($0.connection.endpoint.recvQueue)" }),
            number("fd", "FD", width: 50,
                   help: "The socket's file descriptor number in the process",
                   value: { $0.connection.fd }, text: { "\($0.connection.fd)" }),
        ]
    }
}

struct DiskView: View {
    @ObservedObject private var store = ProcessStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Binding var search: String
    var active = true
    @State private var activeOnly = true

    var body: some View {
        TableUnderToolbar {
            FilterBar {
                Toggle("Only processes with recent disk activity", isOn: $activeOnly).toggleStyle(.checkbox).fixedSize()
            } trailing: {
                Text("Read \(Fmt.rate(store.system.diskReadRate).ifEmpty("0 B/s")) · Write \(Fmt.rate(store.system.diskWriteRate).ifEmpty("0 B/s"))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        } table: { topInset in
            OutlineTable(
                roots: active ? rows : [],
                children: nil,
                revision: store.revision &+ (activeOnly ? 1 : 0) &+ search.hashValue &+ (settings.searchUsesRegex ? 4 : 0),
                columns: Self.columns,
                autosaveName: "DiskTable",
                key: { AnyHashable($0.key) },
                rowStyle: { Highlighter.style(for: $0) },
                menu: { ProcessMenu.build(for: $0) },
                onDoubleClick: { PropertiesWindow.open($0) },
                defaultSort: (column: "total", ascending: false),
                font: settings.processListFont,
                iconSize: settings.processListIconSize,
                isActive: active,
                topInset: topInset)
        }
    }

    private var rows: [ProcessItem] {
        let m = settings.matcher(search)
        return store.items.values.filter { p in
            guard !p.isRemoved, p.stats != nil else { return false }
            if activeOnly, p.ioTotalRate == 0, !p.ioHistory.anyRecent(10) { return false }
            if !m.isEmpty, !m.matchesAny(p.name, p.record.path), !m.matchesIdentifier("\(p.pid)") { return false }
            return true
        }
    }

    static let columns: [TableColumnSpec<ProcessItem>] = {
        var name = TableColumnSpec<ProcessItem>.string("name", "Name", width: 200, help: "The process's executable name") { $0.name }
        name.image = { ProcessIcons.icon(for: $0.record) }
        var graph = TableColumnSpec<ProcessItem>("graph", "History", width: 100,
                                                 help: "Disk read + write rate over the last 120 updates; sorts by current rate",
                                                 text: { _ in "" }, less: { $0.ioTotalRate < $1.ioTotalRate })
        graph.kind = .graph
        graph.graph = { GraphCellData(values: $0.ioHistory.ordered, maxValue: max(1, $0.ioHistory.maxValue), color: .systemBlue) }
        return [
            name,
            .number("pid", "PID", width: 60, help: "Process ID", value: { $0.pid }, text: { "\($0.pid)" }),
            .number("read", "Read rate", width: 90,
                    help: "Bytes read from disk per second",
                    value: { $0.diskReadRate }, text: { Fmt.rate($0.diskReadRate) }),
            .number("write", "Write rate", width: 90,
                    help: "Bytes written to disk per second",
                    value: { $0.diskWriteRate }, text: { Fmt.rate($0.diskWriteRate) }),
            .number("total", "Total rate", width: 90,
                    help: "Bytes read and written per second",
                    value: { $0.ioTotalRate }, text: { Fmt.rate($0.ioTotalRate) }),
            graph,
            .number("readTotal", "Total read", width: 90,
                    help: "Bytes read from disk since the process started",
                    value: { $0.stats?.diskBytesRead ?? 0 }, text: { Fmt.bytes($0.stats?.diskBytesRead ?? 0) }),
            .number("writeTotal", "Total written", width: 90,
                    help: "Bytes written to disk since the process started",
                    value: { $0.stats?.diskBytesWritten ?? 0 }, text: { Fmt.bytes($0.stats?.diskBytesWritten ?? 0) }),
            .number("logical", "Logical writes", width: 90,
                    help: "Bytes written to files since the process started, counted as they're written rather than as they reach the disk",
                    value: { $0.stats?.logicalWrites ?? 0 }, text: { Fmt.bytes($0.stats?.logicalWrites ?? 0) }),
            .string("user", "User", width: 90, help: "The user the process runs as (its effective user)") { $0.userName },
            .string("path", "File name", width: 300, visible: false, help: "Full path of the executable") { $0.record.path ?? "" },
        ]
    }()
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// Filter row above a list: leading controls scroll horizontally when the window is too narrow
/// (instead of squeezing their labels), trailing status stays pinned right.
struct FilterBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    leading
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Soft edge so controls cut off in a narrow window read as scrollable, not broken.
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 18)
                }
            }
            HStack(spacing: 8) {
                trailing
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
