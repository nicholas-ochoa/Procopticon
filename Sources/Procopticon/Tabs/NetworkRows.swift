import AppKit
import ProcopticonCore

/// What one connection row of the Network tab stands for: a socket, or, under its process, every
/// socket of the process that would read the same (a browser's six connections to one server).
struct NetworkEntry {
    var key: AnyHashable
    /// Never empty. They agree on everything `NetworkRow.grouped` merges by, so the first speaks
    /// for all of them except in the local port, the queues and the file descriptor.
    var items: [ConnectionItem]

    var first: ConnectionItem { items[0] }
    var endpoint: SocketEndpoint { first.connection.endpoint }
}

/// A process's connections, under one row of the Network tab.
struct NetworkProcessGroup {
    var pid: Int32
    var name: String
    var entries: [NetworkEntry]
    /// How many sockets the entries stand for.
    var count: Int
}

/// A row of the Network tab: a connection, or the process its connections are grouped under.
enum NetworkRow {
    case process(NetworkProcessGroup)
    /// `nested` under its process's row: the row is then named for the connection, not the process.
    case connection(NetworkEntry, nested: Bool)

    var key: AnyHashable {
        switch self {
        case .process(let group): AnyHashable("process-\(group.pid)")
        case .connection(let entry, _): entry.key
        }
    }

    var pid: Int32 {
        switch self {
        case .process(let group): group.pid
        case .connection(let entry, _): entry.first.connection.pid
        }
    }

    var processName: String {
        switch self {
        case .process(let group): group.name
        case .connection(let entry, _): entry.first.connection.processName
        }
    }

    var entry: NetworkEntry? {
        if case .connection(let entry, _) = self { return entry }
        return nil
    }

    var isNested: Bool {
        if case .connection(_, true) = self { return true }
        return false
    }

    var children: [NetworkRow] {
        if case .process(let group) = self { return group.entries.map { .connection($0, nested: true) } }
        return []
    }

    /// One row per socket.
    static func list(_ items: [ConnectionItem]) -> [NetworkRow] {
        items.map { .connection(NetworkEntry(key: AnyHashable($0.id), items: [$0]), nested: false) }
    }

    /// One row per process, by name, with its connections under it. Sockets of a process that
    /// differ only in what the system assigned them (the local port, the descriptor) share a row.
    /// Connections just opened or closed keep rows of their own while they're highlighted as such,
    /// so that the highlight says which one it was.
    static func grouped(_ items: [ConnectionItem], isNew: (ConnectionItem) -> Bool) -> [NetworkRow] {
        Dictionary(grouping: items) { $0.connection.pid }
            .map { pid, sockets in
                var entries: [NetworkEntry] = []
                var index: [String: Int] = [:]
                for item in sockets {
                    let e = item.connection.endpoint
                    let ends = e.hasPeer ? "\(e.localAddress)>\(e.remoteAddress):\(e.remotePort)" : "\(e.localAddress):\(e.localPort)"
                    let phase = item.removedAt != nil ? "closed" : isNew(item) ? "new" : ""
                    let key = "merged-\(pid)|\(e.protocolName)|\(e.tcpState)|\(ends)|\(phase)"
                    if let i = index[key] {
                        entries[i].items.append(item)
                    } else {
                        index[key] = entries.count
                        entries.append(NetworkEntry(key: AnyHashable(key), items: [item]))
                    }
                }
                return NetworkProcessGroup(pid: pid, name: sockets[0].connection.processName, entries: entries, count: sockets.count)
            }
            .sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.pid < b.pid : order == .orderedAscending
            }
            .map { .process($0) }
    }

    /// The order of rows the sorted column doesn't tell apart: by process, then what the process
    /// listens on, then what it's connected to. The store lists connections in no order at all,
    /// which would otherwise shuffle such rows from one refresh to the next.
    static func inDisplayOrder(_ a: ConnectionItem, _ b: ConnectionItem) -> Bool {
        let x = a.connection, y = b.connection
        if x.pid != y.pid {
            let order = x.processName.localizedStandardCompare(y.processName)
            return order == .orderedSame ? x.pid < y.pid : order == .orderedAscending
        }
        let e = x.endpoint, f = y.endpoint
        let connected = (e.hasPeer, f.hasPeer)
        if connected.0 != connected.1 { return !connected.0 }
        if !connected.0 {
            // Sockets bound to a port before the ones that aren't.
            if (e.localPort == 0) != (f.localPort == 0) { return e.localPort != 0 }
            if e.localPort != f.localPort { return e.localPort < f.localPort }
        } else if e.remoteAddress != f.remoteAddress {
            return e.remoteAddress.compare(f.remoteAddress, options: .numeric) == .orderedAscending
        } else if e.remotePort != f.remotePort {
            return e.remotePort < f.remotePort
        }
        return (e.localPort, x.fd) < (f.localPort, y.fd)
    }
}

/// How the Network tab writes a connection, and the colors of its values: what says little is
/// dimmed, and the states worth noticing are colored. Colors only; table cells supply the font.
enum ConnectionStyle {
    private static func text(_ string: String, _ color: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(string: string, attributes: color.map { [.foregroundColor: $0] } ?? [:])
    }

    private static var dim: NSColor { .secondaryLabelColor }

    /// Several values in one cell, each once.
    static func joined(_ parts: [NSAttributedString]) -> NSAttributedString {
        var seen = Set<String>()
        let result = NSMutableAttributedString()
        for part in parts where seen.insert(part.string).inserted {
            if result.length > 0 { result.append(text(", ", dim)) }
            result.append(part)
        }
        return result
    }

    /// Loopback addresses dimmed: traffic that never leaves this Mac.
    static func address(_ address: String) -> NSAttributedString {
        text(address, HostNames.isLoopback(address) ? dim : nil)
    }

    /// Ports the system picked itself dimmed, leaving the ones that name a service.
    static func port(_ port: UInt16) -> NSAttributedString {
        port == 0 ? NSAttributedString() : text("\(port)", PortNames.isEphemeral(port) ? dim : nil)
    }

    /// A host name with everything before its registered domain dimmed, and all of it for a
    /// loopback address.
    static func host(_ host: String, address: String) -> NSAttributedString {
        if HostNames.isLoopback(address) { return text(host, dim) }
        let parts = HostNames.split(host)
        guard !parts.prefix.isEmpty else { return text(host) }
        let result = NSMutableAttributedString(attributedString: text(parts.prefix, dim))
        result.append(text(parts.domain))
        return result
    }

    /// ":443", dimmed for a port the system picked, and nothing for no port.
    private static func portSuffix(_ port: UInt16) -> NSAttributedString {
        port == 0 ? NSAttributedString() : text(":\(port)", PortNames.isEphemeral(port) ? dim : nil)
    }

    /// The name /etc/services has for the port, set off from it and dimmed: it's what the port is
    /// usually for, not what was seen on the wire.
    private static func serviceSuffix(_ service: String) -> NSAttributedString {
        service.isEmpty ? NSAttributedString() : text("  \(service)", dim)
    }

    /// The far end as "host:port service", with the address where no name is known for it.
    /// Nothing for a socket without a far end.
    static func remote(_ item: ConnectionItem) -> NSAttributedString {
        let e = item.connection.endpoint
        guard e.hasPeer else { return NSAttributedString() }
        let name = item.remoteHost
        let result = NSMutableAttributedString(attributedString: name.isEmpty
            ? address(SocketEndpoint.bracket(e.remoteAddress)) : host(name, address: e.remoteAddress))
        result.append(portSuffix(e.remotePort))
        result.append(serviceSuffix(item.remoteService))
        return result
    }

    /// The near end. A connection's is written as its port alone (":51455"), because its address
    /// is this Mac's own on nearly every row; a loopback address is kept, since it says the
    /// connection stays on this Mac. A socket that only listens has its address in full, which
    /// says who can reach it: "*" for anyone, 127.0.0.1 for this Mac only.
    static func local(_ entry: NetworkEntry) -> NSAttributedString {
        let e = entry.endpoint
        guard e.hasPeer else {
            if e.localPort == 0, e.localAddress == "*" { return NSAttributedString() }
            let result = NSMutableAttributedString(attributedString: address(SocketEndpoint.bracket(e.localAddress)))
            result.append(portSuffix(e.localPort))
            return result
        }
        let result = NSMutableAttributedString()
        if HostNames.isLoopback(e.localAddress) {
            result.append(address(SocketEndpoint.bracket(e.localAddress)))
        }
        result.append(joined(entry.items.map { portSuffix($0.connection.endpoint.localPort) }))
        return result
    }

    /// The near end in full, as `local` is copied and exported.
    static func localText(_ entry: NetworkEntry) -> String {
        var seen = Set<String>()
        return entry.items.compactMap { item -> String? in
            let e = item.connection.endpoint
            if e.localPort == 0, e.localAddress == "*" { return nil }
            let text = SocketEndpoint.bracket(e.localAddress) + (e.localPort == 0 ? "" : ":\(e.localPort)")
            return seen.insert(text).inserted ? text : nil
        }.joined(separator: ", ")
    }

    /// What a connection's row is called under its process: the far end for a connection, the
    /// port for a socket that waits on one, then how many sockets the row stands for.
    static func label(_ entry: NetworkEntry) -> NSAttributedString {
        let e = entry.endpoint
        let result = NSMutableAttributedString()
        if e.hasPeer {
            result.append(remote(entry.first))
        } else if e.localPort != 0 {
            // A UDP socket bound to a port receives on it without a listening state to say so.
            result.append(text(e.isListening || e.proto != IPPROTO_TCP ? "Listening on " : "Bound to "))
            result.append(address(SocketEndpoint.bracket(e.localAddress)))
            result.append(portSuffix(e.localPort))
            result.append(serviceSuffix(entry.first.localService))
        } else {
            result.append(text("Unbound socket", dim))
        }
        if entry.items.count > 1 {
            result.append(text("  ×\(entry.items.count)", dim))
        }
        return result
    }

    /// Every socket of a row in full, one to a line, for its tooltip.
    static func summary(_ entry: NetworkEntry) -> String {
        let limit = 20
        var lines = entry.items.prefix(limit).map { $0.connection.endpoint.summary }
        if entry.items.count > limit {
            lines.append("and \(entry.items.count - limit) more")
        }
        return lines.joined(separator: "\n")
    }

    /// Listening in blue, a handshake still under way in orange, and closing or closed dimmed;
    /// an established connection, the usual case, stays plain.
    static func state(_ endpoint: SocketEndpoint) -> NSAttributedString {
        let name = endpoint.stateName
        guard endpoint.proto == IPPROTO_TCP else { return text(name) }
        switch endpoint.tcpState {
        case 1: return text(name, .systemBlue)
        case 2, 3: return text(name, .systemOrange)
        case 4: return text(name)
        default: return text(name, dim)
        }
    }

    /// An empty queue dimmed, so that data waiting in one shows.
    static func queue(_ bytes: UInt32) -> NSAttributedString {
        text("\(bytes)", bytes == 0 ? dim : nil)
    }

    /// The process's name, then how many connections are listed under it.
    static func group(_ group: NetworkProcessGroup) -> NSAttributedString {
        let result = NSMutableAttributedString(string: group.name)
        result.append(text("  \(group.count)", dim))
        return result
    }
}
