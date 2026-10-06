import Combine
import Darwin
import Foundation

public final class ConnectionItem: Identifiable {
    public let id: String
    public private(set) var connection: NetworkConnection
    public let firstSeen = Date()
    public var removedAt: Date?
    public var isInitial: Bool

    init(_ c: NetworkConnection, initial: Bool) {
        id = c.id
        connection = c
        isInitial = initial
    }

    func update(_ c: NetworkConnection) {
        connection = c
    }

    public var localHost: String { ReverseDNS.shared.name(for: connection.endpoint.localAddress) ?? "" }
    public var remoteHost: String { ReverseDNS.shared.name(for: connection.endpoint.remoteAddress) ?? "" }
    public var localService: String { PortNames.name(port: connection.endpoint.localPort, proto: connection.endpoint.proto) }
    public var remoteService: String { PortNames.name(port: connection.endpoint.remotePort, proto: connection.endpoint.proto) }
}

/// Periodically enumerates TCP/UDP endpoints of every accessible process.
public final class NetworkStore: ObservableObject {
    public static let shared = NetworkStore()

    @Published public private(set) var revision = 0
    public private(set) var items: [ConnectionItem] = []
    public var highlightDuration: TimeInterval = 2
    public var resolveAddresses = true
    private var map: [String: ConnectionItem] = [:]
    private var timer: Timer?
    private var busy = false
    private var hasSampled = false
    private let queue = DispatchQueue(label: "network-sampler", qos: .utility)
    private var activeObservers = 0

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
        queue.async { [weak self] in
            let response = Elevation.shared.perform(.connections)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if case .connections(let list) = response {
                    self.merge(list)
                }
            }
        }
    }

    private func merge(_ list: [NetworkConnection]) {
        var seen = Set<String>()
        for c in list {
            seen.insert(c.id)
            if let item = map[c.id] {
                item.update(c)
            } else {
                let item = ConnectionItem(c, initial: !hasSampled)
                map[c.id] = item
                if resolveAddresses {
                    ReverseDNS.shared.resolve(c.endpoint.remoteAddress)
                }
            }
        }
        let now = Date()
        for (id, item) in map where !seen.contains(id) {
            if let removed = item.removedAt {
                if now.timeIntervalSince(removed) >= highlightDuration {
                    map.removeValue(forKey: id)
                }
            } else {
                item.removedAt = now
            }
        }
        hasSampled = true
        items = Array(map.values)
        revision &+= 1
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
