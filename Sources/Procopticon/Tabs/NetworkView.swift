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

    var body: some View {
        TableUnderToolbar {
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
                Toggle("Hide listening", isOn: $hideListening).toggleStyle(.checkbox).fixedSize()
                Toggle("Hide loopback", isOn: $hideLoopback).toggleStyle(.checkbox).fixedSize()
                Toggle("Resolve addresses", isOn: $settings.resolveAddresses).toggleStyle(.checkbox).fixedSize()
            } trailing: {
                if Elevation.shared.mode == .standard {
                    Image(systemName: "lock").foregroundStyle(.secondary).help("Showing your processes only — authorize to see all connections")
                }
                Text("\(filtered.count) connections").foregroundStyle(.secondary).lineLimit(1)
            }
        } table: { topInset in
            OutlineTable(
                roots: filtered,
                children: nil,
                revision: store.revision &+ search.hashValue &+ (settings.searchUsesRegex ? 4 : 0) &+ protocolFilter.hashValue &+ (hideListening ? 1 : 0) &+ (hideLoopback ? 2 : 0),
                columns: Self.columns,
                autosaveName: "NetworkTable",
                key: { AnyHashable($0.id) },
                rowStyle: { style($0) },
                menu: { menu($0) },
                onDoubleClick: { c in
                    if let p = ProcessStore.shared.item(pid: c.connection.pid) { PropertiesWindow.open(p) }
                },
                defaultSort: (column: "process", ascending: true),
                isActive: active,
                topInset: topInset)
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
            if hideLoopback, isLoopback(e.localAddress), isLoopback(e.remoteAddress) || e.remoteAddress == "*" { return false }
            if m.isEmpty { return true }
            return m.matchesAny(item.connection.processName, e.localAddress, e.remoteAddress, item.remoteHost, item.remoteService)
                || m.matchesIdentifier("\(e.localPort)") || m.matchesIdentifier("\(e.remotePort)")
                || m.matchesIdentifier("\(item.connection.pid)")
        }
    }

    private func isLoopback(_ a: String) -> Bool {
        a.hasPrefix("127.") || a == "::1"
    }

    private func style(_ c: ConnectionItem) -> RowStyle? {
        let h = AppSettings.shared.highlights
        if c.removedAt != nil, let s = h[.removed], s.enabled { return RowStyle(background: s.color.withAlphaComponent(0.5)) }
        if store.isNew(c), let s = h[.new], s.enabled { return RowStyle(background: s.color.withAlphaComponent(0.5)) }
        return nil
    }

    private func menu(_ rows: [ConnectionItem]) -> NSMenu {
        let m = NSMenu()
        guard let c = rows.first else { return m }
        let pid = c.connection.pid
        m.add("Go to Process", image: "arrow.right.circle") { ProcessSelection.shared.reveal(pid: pid) }
        if let p = ProcessStore.shared.item(pid: pid) {
            m.add("Process Properties") { PropertiesWindow.open(p) }
            m.add("Terminate Process") { ProcessActions.terminate([p]) }
        }
        m.addItem(.separator())
        let remote = c.connection.endpoint.remoteAddress
        if remote != "*", !remote.isEmpty {
            m.add("Look Up Remote Address (whois)…") {
                Reports.show(title: "whois \(remote)") {
                    ToolRunner.run("/usr/bin/whois", [remote], timeout: 30).combined
                }
            }
            m.add("Copy Remote Address") { ProcessActions.copy(remote) }
        }
        return m
    }

    static let columns: [TableColumnSpec<ConnectionItem>] = {
        var process = TableColumnSpec<ConnectionItem>.string("process", "Name", width: 180,
                                                             help: "The process the socket belongs to") { $0.connection.processName }
        process.image = { c in
            if let p = ProcessStore.shared.item(pid: c.connection.pid) { return ProcessIcons.icon(for: p.record) }
            return ProcessIcons.executable
        }
        return [
            process,
            .number("pid", "PID", width: 60, help: "Process ID", value: { $0.connection.pid }, text: { "\($0.connection.pid)" }),
            .string("proto", "Protocol", width: 60, help: "TCP or UDP; TCP6 and UDP6 are IPv6") { $0.connection.endpoint.protocolName },
            .string("laddr", "Local address", width: 150, help: "Local IP address (* means any)") { $0.connection.endpoint.localAddress },
            .number("lport", "Local port", width: 70, help: "Local port", value: { $0.connection.endpoint.localPort }, text: { p in
                let e = p.connection.endpoint
                return e.localPort == 0 ? "" : "\(e.localPort)"
            }),
            .string("lhost", "Local host", width: 120, visible: false, help: "Local address resolved to a host name") { $0.localHost },
            .string("lservice", "Local service", width: 90, visible: false,
                    help: "Service name for the local port (from /etc/services)") { $0.localService },
            .string("raddr", "Remote address", width: 150,
                    help: "Remote IP address") { $0.connection.endpoint.remoteAddress == "*" ? "" : $0.connection.endpoint.remoteAddress },
            .number("rport", "Remote port", width: 75, help: "Remote port", value: { $0.connection.endpoint.remotePort }, text: { p in
                let e = p.connection.endpoint
                return e.remotePort == 0 ? "" : "\(e.remotePort)"
            }),
            .string("rhost", "Remote host", width: 200,
                    help: "Remote address resolved to a host name, when that's turned on in Settings") { $0.remoteHost },
            .string("rservice", "Remote service", width: 90, help: "Service name for the remote port (from /etc/services)") { $0.remoteService },
            .string("state", "State", width: 90,
                    help: "TCP connection state, such as Listen or Established (blank for UDP)") { $0.connection.endpoint.stateName },
            .number("sendq", "Send queue", width: 70, visible: false,
                    help: "Bytes waiting in the socket's send buffer",
                    value: { $0.connection.endpoint.sendQueue }, text: { "\($0.connection.endpoint.sendQueue)" }),
            .number("recvq", "Receive queue", width: 70, visible: false,
                    help: "Bytes received but not yet read by the process",
                    value: { $0.connection.endpoint.recvQueue }, text: { "\($0.connection.endpoint.recvQueue)" }),
            .number("fd", "FD", width: 50, visible: false,
                    help: "The socket's file descriptor number in the process",
                    value: { $0.connection.fd }, text: { "\($0.connection.fd)" }),
        ]
    }()
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
