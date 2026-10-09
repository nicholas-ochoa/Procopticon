import Darwin
import Foundation

/// One file system call or disk I/O, as `fs_usage -w -f filesys` reports it.
public struct FileEvent: Identifiable, Hashable, Sendable {
    public var id: Int
    /// Time of day, to the microsecond.
    public var time: String
    /// The system call (open, read, stat64…) or disk operation (RdData, WrMeta…).
    public var call: String
    /// The path the call names, or the file its descriptor refers to (see `FileActivityTracker`).
    public var path: String
    /// Whether `path` came from the descriptor rather than the call itself.
    public var pathFromDescriptor = false
    public var descriptor: Int32?
    public var bytes: UInt64?
    /// Seconds the call took.
    public var duration: Double
    /// The error the call failed with, if it did.
    public var errorNumber: Int32?
    /// The thread waited (blocked) during the call.
    public var waited: Bool
    /// Other fields: offsets, open mode, fcntl command, device.
    public var details: String
    /// The process name as fs_usage shows it (truncated), and the thread.
    public var command: String
    public var thread: String

    public var isDiskIO: Bool { call.hasPrefix("Rd") || call.hasPrefix("Wr") || call.hasPrefix("Pg") }
    public var isRead: Bool { call.hasPrefix("Rd") || call.hasPrefix("read") || call.hasPrefix("pread") || call == "getdirentries64" }
    public var isWrite: Bool { call.hasPrefix("Wr") || call.hasPrefix("write") || call.hasPrefix("pwrite") }
    public var errorDescription: String {
        guard let errorNumber else { return "" }
        return String(cString: strerror(errorNumber))
    }
}

public enum FileActivity {
    public static func arguments(pid: Int32) -> [String] {
        ["-w", "-f", "filesys", "\(pid)"]
    }

    private static let line = try! NSRegularExpression(
        pattern: #"^(\d\d:\d\d:\d\d\.\d+)\s+(\S+)\s*(.*?)\s+(\d+\.\d+)( W)?\s+(\S.*)$"#)

    /// Parses one line of output; nil for headers and anything else.
    public static func parse(_ text: String, id: Int) -> FileEvent? {
        let ns = text as NSString
        guard let m = line.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        var middle = Substring(group(3).trimmingCharacters(in: .whitespaces))
        var details: [String] = []
        var event = FileEvent(id: id, time: group(1), call: group(2), path: "", duration: Double(group(4)) ?? 0,
                              waited: !group(5).isEmpty, details: "", command: "", thread: "")
        // Leading fields, then whatever remains is the path.
        while !middle.isEmpty {
            if middle.hasPrefix("["), let close = middle.firstIndex(of: "]") {
                event.errorNumber = Int32(middle[middle.index(after: middle.startIndex)..<close].trimmingCharacters(in: .whitespaces))
                middle = middle[middle.index(after: close)...]
            } else if middle.hasPrefix("("), let close = middle.firstIndex(of: ")") {
                details.append(String(middle[...close]))
                middle = middle[middle.index(after: close)...]
            } else if middle.hasPrefix("<"), let close = middle.firstIndex(of: ">") {
                details.append(String(middle[...close]))
                middle = middle[middle.index(after: close)...]
            } else if middle.count > 2, middle.dropFirst().first == "=", middle.first?.isUppercase == true {
                let token = middle.prefix { $0 != " " }
                let key = token.first!
                let value = token.dropFirst(2)
                switch key {
                case "F": event.descriptor = Int32(value)
                case "B": event.bytes = UInt64(value.hasPrefix("0x") ? value.dropFirst(2) : value, radix: value.hasPrefix("0x") ? 16 : 10)
                default: details.append(String(token))
                }
                middle = middle.dropFirst(token.count)
            } else if middle.hasPrefix("/dev/"), event.isDiskIO {
                let device = middle.prefix { $0 != " " }
                details.append(String(device))
                middle = middle.dropFirst(device.count)
            } else {
                break
            }
            middle = middle.drop { $0 == " " }
        }
        event.path = String(middle).trimmingCharacters(in: .whitespaces)
        event.details = details.joined(separator: " ")
        let process = group(6).trimmingCharacters(in: .whitespaces)
        if let dot = process.lastIndex(of: "."), process[process.index(after: dot)...].allSatisfy(\.isNumber) {
            event.command = String(process[..<dot])
            event.thread = String(process[process.index(after: dot)...])
        } else {
            event.command = process
        }
        return event
    }

    /// Whether fs_usage's truncated command name could be `name`'s. Disk I/O completions can be
    /// reported for other processes too.
    public static func command(_ command: String, matches name: String) -> Bool {
        guard !command.isEmpty else { return true }
        let n = min(command.count, name.count, 12)
        return command.prefix(n) == name.prefix(n)
    }
}

/// Follows the descriptors a process opens so reads and writes can name their file.
public struct FileActivityTracker {
    private var paths: [Int32: String] = [:]

    public init(openFiles: [Int32: String] = [:]) {
        paths = openFiles
    }

    public mutating func track(_ event: inout FileEvent) {
        guard let fd = event.descriptor, fd >= 0 else { return }
        let call = event.call
        if event.errorNumber == nil, call.hasPrefix("open") || call == "guarded_open_np" || call == "guarded_open_dprotected_np"
            || call == "openat" || call == "open_nocancel", !event.path.isEmpty {
            paths[fd] = event.path
            return
        }
        if call.hasPrefix("close") || call == "guarded_close_np" {
            if event.path.isEmpty, let p = paths[fd] {
                event.path = p
                event.pathFromDescriptor = true
            }
            paths.removeValue(forKey: fd)
            return
        }
        if event.path.isEmpty, let p = paths[fd] {
            event.path = p
            event.pathFromDescriptor = true
        }
    }
}

/// Activity on one file, summed over the events seen.
public struct FileActivitySummary: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var calls = 0
    public var bytesRead: UInt64 = 0
    public var bytesWritten: UInt64 = 0
    public var errors = 0
    public var lastTime = ""
    public var lastCall = ""

    public init(path: String) {
        self.path = path
    }

    public mutating func add(_ e: FileEvent) {
        calls += 1
        if e.isRead { bytesRead &+= e.bytes ?? 0 }
        if e.isWrite { bytesWritten &+= e.bytes ?? 0 }
        if e.errorNumber != nil { errors += 1 }
        lastTime = e.time
        lastCall = e.call
    }
}
