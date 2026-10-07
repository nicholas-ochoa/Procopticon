import Foundation

/// Network interface totals. Processes without the network statistics entitlement get interface
/// byte counts from the kernel truncated to 32 bits (and rounded to the kilobyte), so they wrap
/// every 4 GiB. True totals come from netstat, which has the entitlement, once; after that,
/// wrap-aware growth between samples keeps them current.
public enum InterfaceCounters {
    public struct Totals: Equatable, Sendable {
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

        init(_ i: NetInterfaceStats) {
            self.init(bytesIn: i.ibytes, bytesOut: i.obytes, packetsIn: i.ipackets, packetsOut: i.opackets)
        }
    }

    /// How much a counter grew between two samples. A drop from the upper half of the 32-bit range
    /// to the lower half is a wrap; any other drop means the counter restarted (e.g. the interface
    /// was recreated), so it grew by its new value.
    public static func growth(_ new: UInt64, _ old: UInt64) -> UInt64 {
        if new >= old {
            return new - old
        }
        let half: UInt64 = 1 << 31
        if old <= UInt64(UInt32.max), old >= half, new < half {
            return new &+ (1 << 32) &- old
        }
        return new
    }

    /// Totals by interface name from `netstat -ibn`, or nil if it couldn't be run.
    public static func netstat() -> [String: Totals]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Reads the link-level line of each interface: "Name Mtu <Link#n> [Address] Ipkts Ierrs Ibytes
    /// Opkts Oerrs Obytes Coll". The address is missing for some, so values are read from the end.
    static func parse(_ text: String) -> [String: Totals] {
        var result: [String: Totals] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 10, fields[2].hasPrefix("<Link#") else { continue }
            let n = fields.count
            func value(_ fromEnd: Int) -> UInt64 { UInt64(fields[n - fromEnd]) ?? 0 }
            var name = String(fields[0])
            if name.hasSuffix("*") {
                name.removeLast()
            }
            result[name] = Totals(bytesIn: value(5), bytesOut: value(2), packetsIn: value(7), packetsOut: value(4))
        }
        return result
    }
}
