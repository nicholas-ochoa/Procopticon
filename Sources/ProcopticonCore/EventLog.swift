import Combine
import Foundation

/// In-memory log of process and service lifecycle events.
public final class EventLog: ObservableObject {
    public static let shared = EventLog()

    public enum Kind: String, Sendable {
        case processStarted = "Process started"
        case processExited = "Process exited"
        case notResponding = "Not responding"
        case responding = "Responding again"
        case power = "Power"
        case privacy = "Microphone, camera, screen"
        case alert = "Alert"
        case serviceStarted = "Service started"
        case serviceStopped = "Service stopped"
        case action = "Action"
        case elevation = "Privileges"
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: Int
        public let date: Date
        public let kind: Kind
        public let pid: Int32?
        public let message: String
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public var enabled = true
    private var nextId = 0
    public var capacity = 5000

    public func add(_ kind: Kind, pid: Int32? = nil, _ message: String) {
        guard enabled else { return }
        let run = { [self] in
            nextId += 1
            entries.append(Entry(id: nextId, date: Date(), kind: kind, pid: pid, message: message))
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    public func clear() {
        entries.removeAll()
    }
}
