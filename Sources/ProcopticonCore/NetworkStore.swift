import Combine
import Darwin
import Foundation

/// Immutable snapshot of one connection (rebuilt on every refresh, safe to read from any thread).
public final class ConnectionItem: Identifiable {
    public let id: String
    public let connection: NetworkConnection
    public let firstSeen: Date
    public let removedAt: Date?
    public let isInitial: Bool

    init(_ c: NetworkConnection, firstSeen: Date, removedAt: Date?, initial: Bool) {
        id = c.id
        connection = c
        self.firstSeen = firstSeen
        self.removedAt = removedAt
        isInitial = initial
    }

    public var localHost: String { ReverseDNS.shared.name(for: connection.endpoint.localAddress) ?? "" }
    public var remoteHost: String { ReverseDNS.shared.name(for: connection.endpoint.remoteAddress) ?? "" }
    public var localService: String { PortNames.name(port: connection.endpoint.localPort, proto: connection.endpoint.proto) }
    public var remoteService: String { PortNames.name(port: connection.endpoint.remotePort, proto: connection.endpoint.proto) }
}

/// Periodically enumerates TCP/UDP endpoints of every accessible process.
///
/// Enumeration and merging run on a private queue; the main thread receives finished snapshots.
public final class NetworkStore: ObservableObject {
    public static let shared = NetworkStore()

    @Published public private(set) var revision = 0
    public private(set) var items: [ConnectionItem] = []
    public var highlightDuration: TimeInterval = 2
    public var resolveAddresses = true
    private var timer: Timer?
    private var busy = false
    private let queue = DispatchQueue(label: "network-sampler", qos: .utility)
    private var activeObservers = 0

    // Background-queue state.
    private struct Tracked {
        var connection: NetworkConnection
        var firstSeen: Date
        var removedAt: Date?
        var initial: Bool
    }
    private var tracked: [String: Tracked] = [:]
    private var hasSampled = false

    public init() {}

    /// Sampling only runs while at least one view is interested.
    public func retain(interval: TimeInterval) {
        activeObservers += 1
        if timer == nil {
            refresh()
            let t = Timer(timeInterval: max(1, interval), repeats: true) { [weak self] _ in
                guard !(ProcessStore.shared.paused) else { return }
                self?.refresh()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    public func release() {
        activeObservers = max(0, activeObservers - 1)
        if activeObservers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    public func refresh() {
        guard !busy else { return }
        busy = true
        let highlight = highlightDuration
        let resolve = resolveAddresses
        queue.async { [weak self] in
            guard let self else { return }
            let response = Elevation.shared.perform(.connections)
            var snapshot: [ConnectionItem]?
            if case .connections(let list) = response {
                snapshot = self.merge(list, highlight: highlight, resolve: resolve)
            }
            DispatchQueue.main.async {
                self.busy = false
                if let snapshot {
                    self.items = snapshot
                    self.revision &+= 1
                }
            }
        }
    }

    private func merge(_ list: [NetworkConnection], highlight: TimeInterval, resolve: Bool) -> [ConnectionItem] {
        let now = Date()
        var seen = Set<String>()
        for c in list {
            seen.insert(c.id)
            if tracked[c.id] != nil {
                tracked[c.id]?.connection = c
            } else {
                tracked[c.id] = Tracked(connection: c, firstSeen: now, removedAt: nil, initial: !hasSampled)
                if resolve {
                    ReverseDNS.shared.resolve(c.endpoint.remoteAddress)
                }
            }
        }
        for (id, t) in tracked where !seen.contains(id) {
            if let removed = t.removedAt {
                if now.timeIntervalSince(removed) >= highlight {
                    tracked.removeValue(forKey: id)
                }
            } else {
                tracked[id]?.removedAt = now
            }
        }
        hasSampled = true
        return tracked.values.map { ConnectionItem($0.connection, firstSeen: $0.firstSeen, removedAt: $0.removedAt, initial: $0.initial) }
    }

    public func isNew(_ item: ConnectionItem) -> Bool {
        !item.isInitial && item.removedAt == nil && Date().timeIntervalSince(item.firstSeen) < highlightDuration
    }
}

/// Asynchronous reverse DNS with caching.
public final class ReverseDNS: @unchecked Sendable {
    public static let shared = ReverseDNS()
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var pending = Set<String>()
    private let queue = DispatchQueue(label: "rdns", qos: .utility, attributes: .concurrent)
    private let limiter = DispatchSemaphore(value: 8)

    public func name(for address: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[address]
    }

    public func resolve(_ address: String) {
        guard !address.isEmpty, address != "*" else { return }
        lock.lock()
        if cache[address] != nil || pending.contains(address) {
            lock.unlock()
            return
        }
        pending.insert(address)
        lock.unlock()
        queue.async { [self] in
            limiter.wait()
            defer { limiter.signal() }
            let name = Self.lookup(address) ?? ""
            lock.lock()
            cache[address] = name
            pending.remove(address)
            lock.unlock()
        }
    }

    static func lookup(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else {
            return nil
        }
        return String(cString: host)
    }
}

public enum PortNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    public static func name(port: UInt16, proto: Int32) -> String {
        guard port != 0 else { return "" }
        let protoName = proto == IPPROTO_UDP ? "udp" : "tcp"
        let key = "\(port)/\(protoName)"
        lock.lock()
        defer { lock.unlock() }
        if let c = cache[key] { return c }
        var name = ""
        if let ent = getservbyport(Int32(UInt16(port).bigEndian), protoName) {
            name = String(cString: ent.pointee.s_name)
        }
        cache[key] = name
        return name
    }
}
