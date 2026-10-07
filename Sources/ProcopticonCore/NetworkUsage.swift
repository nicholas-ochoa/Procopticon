import Foundation

/// A process's network traffic: totals for its sockets, as nettop reports them.
public struct NetworkCounters: Equatable, Sendable {
    public var bytesIn: UInt64 = 0
    public var bytesOut: UInt64 = 0
    public var packetsIn: UInt64 = 0
    public var packetsOut: UInt64 = 0

    public init(bytesIn: UInt64 = 0, bytesOut: UInt64 = 0, packetsIn: UInt64 = 0, packetsOut: UInt64 = 0) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
    }
}

/// Per-process network traffic, read with nettop. The kernel's network statistics only describe
/// other users' processes to clients holding a private entitlement, which nettop has and this app
/// can't, so one nettop sample (10–20 ms) is taken per refresh.
public enum NetworkUsage {
    static let columns = ["bytes_in", "bytes_out", "packets_in", "packets_out"]

    /// Counters by pid, or nil when nettop couldn't be run.
    public static func sample(timeout: TimeInterval = 3) -> [Int32: NetworkCounters]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // Per-process summaries, one sample in CSV, exact numbers, no name resolution.
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-J", columns.joined(separator: ",")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read while it runs so a full pipe can never stall it.
        let output = OutputBuffer()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
        }
        reading.wait()
        return parse(String(decoding: output.data, as: UTF8.self))
    }

    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }

    /// Parses nettop's CSV: a header naming the columns (in nettop's own order), then one
    /// "name.pid,value,…," row per process.
    static func parse(_ text: String) -> [Int32: NetworkCounters] {
        var result: [Int32: NetworkCounters] = [:]
        var header: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if fields.last == "" {
                fields.removeLast()
            }
            if fields.first == "" || fields.first == "time" {
                header = fields
                continue
            }
            // Without -J, a time column comes before the name.
            let nameColumn = header.first == "time" ? 1 : 0
            guard header.count > nameColumn + 1, fields.count >= header.count else { continue }
            // A comma in the process name splits it across fields; the values are always last.
            let extra = fields.count - header.count
            let name = fields[nameColumn...(nameColumn + extra)].joined(separator: ",")
            guard let dot = name.lastIndex(of: "."), let pid = Int32(name[name.index(after: dot)...]) else { continue }
            var counters = result[pid] ?? NetworkCounters()
            for (index, column) in header.enumerated() where index > nameColumn {
                let value = UInt64(fields[index + extra]) ?? 0
                switch column {
                case "bytes_in": counters.bytesIn &+= value
                case "bytes_out": counters.bytesOut &+= value
                case "packets_in": counters.packetsIn &+= value
                case "packets_out": counters.packetsOut &+= value
                default: break
                }
            }
            result[pid] = counters
        }
        return result
    }
}
