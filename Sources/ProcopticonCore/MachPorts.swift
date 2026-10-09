import Darwin
import Foundation

/// How many Mach port names each process holds. Only `lsmp` can tell (Apple gives it the
/// entitlement to read other tasks' port spaces), it needs root, and listing every process takes
/// about a second and tens of megabytes of output, so this is sampled rarely.
public enum MachPorts {
    /// Port counts by PID from `lsmp -a`, or nil when not running as root.
    public static func counts() -> [Int32: Int]? {
        guard geteuid() == 0 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsmp")
        process.arguments = ["-a"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        var parser = Parser()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            parser.feed(chunk)
        }
        process.waitUntilExit()
        return parser.counts
    }

    /// One process's port count from `lsmp -p` (a tenth of a second), or nil when not running as root.
    public static func count(pid: Int32) -> Int? {
        guard geteuid() == 0 else { return nil }
        let out = ToolRunner.run("/usr/bin/lsmp", ["-p", "\(pid)"], timeout: 10)
        var parser = Parser()
        parser.feed(Data(out.stdout.utf8))
        return parser.counts[pid]
    }

    /// Reads "Process (pid) : name" headers and each process's "total     = n" line, line by line,
    /// so the output never has to be held whole.
    struct Parser {
        private(set) var counts: [Int32: Int] = [:]
        private var pid: Int32?
        private var partial = Data()

        mutating func feed(_ data: Data) {
            var buffer = partial
            buffer.append(data)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                line(buffer[start..<newline])
                start = newline + 1
            }
            partial = Data(buffer[start...])
        }

        private mutating func line(_ bytes: Data) {
            guard let first = bytes.first, first == UInt8(ascii: "P") || first == UInt8(ascii: "t") else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            if text.hasPrefix("Process ("), let close = text.firstIndex(of: ")") {
                pid = Int32(text[text.index(text.startIndex, offsetBy: 9)..<close])
            } else if text.hasPrefix("total"), let pid, let eq = text.firstIndex(of: "=") {
                counts[pid] = Int(text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            }
        }
    }
}
