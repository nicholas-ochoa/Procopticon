import Foundation

public enum Fmt {
    public static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    public static func bytes(_ value: Int64) -> String {
        value < 0 ? "-" + bytes(Double(-value)) : bytes(Double(value))
    }

    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = value
        var i = 0
        while v >= 1024, i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 {
            return String(format: "%.0f B", v)
        }
        return String(format: v >= 100 ? "%.0f %@" : (v >= 10 ? "%.1f %@" : "%.2f %@"), v, units[i])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond <= 0 {
            return ""
        }
        return bytes(bytesPerSecond) + "/s"
    }

    public static func percent(_ value: Double, decimals: Int = 2) -> String {
        if value <= 0 {
            return ""
        }
        if value < 0.01, decimals >= 2 {
            return "< 0.01"
        }
        return String(format: "%.\(decimals)f", value)
    }

    public static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func count(_ value: UInt64) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func delta(_ value: Int64) -> String {
        if value == 0 {
            return ""
        }
        return count(Int(value))
    }

    public static func duration(nanoseconds: UInt64) -> String {
        duration(seconds: Double(nanoseconds) / 1e9)
    }

    /// h:mm:ss.ms style used for CPU time columns.
    public static func duration(seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = total.truncatingRemainder(dividingBy: 60)
        if hours > 0 {
            return String(format: "%d:%02d:%06.3f", hours, minutes, secs)
        }
        return String(format: "%d:%06.3f", minutes, secs)
    }

    /// "3 days, 4 hours" style.
    public static func relative(seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let days = s / 86400
        let hours = (s % 86400) / 3600
        let minutes = (s % 3600) / 60
        let secs = s % 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    public static func date(_ epoch: Double) -> String {
        if epoch <= 0 {
            return ""
        }
        return dateFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    public static func hex(_ value: UInt64) -> String {
        String(format: "0x%llx", value)
    }

    public static func hexAddress(_ value: UInt64) -> String {
        String(format: "0x%012llx", value)
    }

    public static func watts(_ value: Double) -> String {
        if value <= 0 {
            return ""
        }
        if value < 0.001 {
            return String(format: "%.1f mW", value * 1000)
        }
        if value < 1 {
            return String(format: "%.0f mW", value * 1000)
        }
        return String(format: "%.2f W", value)
    }

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

public extension String {
    /// Quote an argument for display/copying as a shell command line.
    var shellQuoted: String {
        if isEmpty {
            return "''"
        }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public extension Array where Element == String {
    var shellJoined: String {
        map(\.shellQuoted).joined(separator: " ")
    }
}

/// Fixed-size ring buffer for graph histories.
public struct History: Sendable {
    public private(set) var values: [Double]
    public let capacity: Int
    private var start = 0
    public private(set) var count = 0

    public init(capacity: Int = 300) {
        self.capacity = capacity
        values = Array(repeating: 0, count: capacity)
    }

    public mutating func append(_ v: Double) {
        let index = (start + count) % capacity
        values[index] = v
        if count < capacity {
            count += 1
        } else {
            start = (start + 1) % capacity
        }
    }

    /// Oldest to newest.
    public var ordered: [Double] {
        (0..<count).map { values[(start + $0) % capacity] }
    }

    public var last: Double {
        count == 0 ? 0 : values[(start + count - 1) % capacity]
    }

    public var maxValue: Double {
        ordered.max() ?? 0
    }
}