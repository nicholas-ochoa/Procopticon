import AppKit
import InformerCore
import SwiftUI

struct NetworkView: View {
    @ObservedObject private var store = NetworkStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Binding var search: String
    @State private var hideListening = false
    @State private var hideLoopback = false
    @State private var protocolFilter = "All"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Protocol", selection: $protocolFilter) {
                    ForEach(["All", "TCP", "UDP"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Toggle("Hide listening", isOn: $hideListening).toggleStyle(.checkbox)
                Toggle("Hide loopback", isOn: $hideLoopback).toggleStyle(.checkbox)
                Toggle("Resolve addresses", isOn: $settings.resolveAddresses).toggleStyle(.checkbox)
                Spacer()
                if Elevation.shared.mode == .standard {
                    Label("Showing your processes only", systemImage: "lock").foregroundStyle(.secondary).font(.caption)
                }
                Text("\(filtered.count) connections").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
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
                defaultSort: (column: "process", ascending: true))
        }
        .onAppear { store.retain(interval: max(1, settings.refreshInterval)) }
        .onDisappear { store.release() }
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
        var process = TableColumnSpec<ConnectionItem>.string("process", "Name", width: 180) { $0.connection.processName }
        process.image = { c in
            if let p = ProcessStore.shared.item(pid: c.connection.pid) { return ProcessIcons.icon(for: p.record) }
            return ProcessIcons.executable
        }
        return [
            process,
            .number("pid", "PID", width: 60, value: { $0.connection.pid }, text: { "\($0.connection.pid)" }),
            .string("proto", "Protocol", width: 60) { $0.connection.endpoint.protocolName },
            .string("laddr", "Local address", width: 150) { $0.connection.endpoint.localAddress },
            .number("lport", "Local port", width: 70, value: { $0.connection.endpoint.localPort }, text: { p in
                let e = p.connection.endpoint
                return e.localPort == 0 ? "" : "\(e.localPort)"
            }),
            .string("lhost", "Local host", width: 120, visible: false) { $0.localHost },
            .string("lservice", "Local service", width: 90, visible: false) { $0.localService },
            .string("raddr", "Remote address", width: 150) { $0.connection.endpoint.remoteAddress == "*" ? "" : $0.connection.endpoint.remoteAddress },
            .number("rport", "Remote port", width: 75, value: { $0.connection.endpoint.remotePort }, text: { p in
                let e = p.connection.endpoint
                return e.remotePort == 0 ? "" : "\(e.remotePort)"
            }),
            .string("rhost", "Remote host", width: 200) { $0.remoteHost },
            .string("rservice", "Remote service", width: 90) { $0.remoteService },
            .string("state", "State", width: 90) { $0.connection.endpoint.stateName },
            .number("sendq", "Send queue", width: 70, visible: false, value: { $0.connection.endpoint.sendQueue }, text: { "\($0.connection.endpoint.sendQueue)" }),
            .number("recvq", "Receive queue", width: 70, visible: false, value: { $0.connection.endpoint.recvQueue }, text: { "\($0.connection.endpoint.recvQueue)" }),
            .number("fd", "FD", width: 50, visible: false, value: { $0.connection.fd }, text: { "\($0.connection.fd)" }),
        ]
    }()
}

struct DiskView: View {
    @ObservedObject private var store = ProcessStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Binding var search: String
    @State private var activeOnly = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Only processes with recent disk activity", isOn: $activeOnly).toggleStyle(.checkbox)
                Spacer()
                Text("Read \(Fmt.rate(store.system.diskReadRate).ifEmpty("0 B/s")) · Write \(Fmt.rate(store.system.diskWriteRate).ifEmpty("0 B/s"))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            OutlineTable(
                roots: rows,
                children: nil,
                revision: store.revision &+ (activeOnly ? 1 : 0) &+ search.hashValue &+ (settings.searchUsesRegex ? 4 : 0),
                columns: Self.columns,
                autosaveName: "DiskTable",
                key: { AnyHashable($0.key) },
                rowStyle: { Highlighter.style(for: $0) },
                menu: { ProcessMenu.build(for: $0) },
                onDoubleClick: { PropertiesWindow.open($0) },
                defaultSort: (column: "total", ascending: false))
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
        var name = TableColumnSpec<ProcessItem>.string("name", "Name", width: 200) { $0.name }
        name.image = { ProcessIcons.icon(for: $0.record) }
        var graph = TableColumnSpec<ProcessItem>("graph", "History", width: 100, text: { _ in "" }, less: { $0.ioTotalRate < $1.ioTotalRate })
        graph.kind = .graph
        graph.graph = { GraphCellData(values: $0.ioHistory.ordered, maxValue: max(1, $0.ioHistory.maxValue), color: .systemBlue) }
        return [
            name,
            .number("pid", "PID", width: 60, value: { $0.pid }, text: { "\($0.pid)" }),
            .number("read", "Read rate", width: 90, value: { $0.diskReadRate }, text: { Fmt.rate($0.diskReadRate) }),
            .number("write", "Write rate", width: 90, value: { $0.diskWriteRate }, text: { Fmt.rate($0.diskWriteRate) }),
            .number("total", "Total rate", width: 90, value: { $0.ioTotalRate }, text: { Fmt.rate($0.ioTotalRate) }),
            graph,
            .number("readTotal", "Total read", width: 90, value: { $0.stats?.diskBytesRead ?? 0 }, text: { Fmt.bytes($0.stats?.diskBytesRead ?? 0) }),
            .number("writeTotal", "Total written", width: 90, value: { $0.stats?.diskBytesWritten ?? 0 }, text: { Fmt.bytes($0.stats?.diskBytesWritten ?? 0) }),
            .number("logical", "Logical writes", width: 90, value: { $0.stats?.logicalWrites ?? 0 }, text: { Fmt.bytes($0.stats?.logicalWrites ?? 0) }),
            .string("user", "User", width: 90) { $0.userName },
            .string("path", "File name", width: 300, visible: false) { $0.record.path ?? "" },
        ]
    }()
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
