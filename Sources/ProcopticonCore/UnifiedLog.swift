import Foundation

/// One message from the unified log, as `log stream --style ndjson` and `log show` write it.
public struct LogEntry: Identifiable, Hashable, Sendable {
    public var id: Int
    public var date: Date
    /// The time of day as logged, to the microsecond ("12:33:35.789327").
    public var time: String
    /// Default, Info, Debug, Error or Fault; or the event type for activities and signposts.
    public var type: String
    public var subsystem: String
    public var category: String
    public var message: String
    /// The library or executable that logged the message.
    public var sender: String
    public var threadID: UInt64
    public var processID: Int32

    public var isError: Bool { type == "Error" }
    public var isFault: Bool { type == "Fault" }
}

public enum UnifiedLog {
    public enum Level: String, CaseIterable, Identifiable, Sendable {
        case `default`, info, debug
        public var id: String { rawValue }
        public var title: String { rawValue == "default" ? "Default" : rawValue.capitalized }
    }

    /// Arguments for `log stream` following one process's messages.
    public static func streamArguments(pid: Int32, level: Level) -> [String] {
        ["stream", "--style", "ndjson", "--level", level.rawValue, "--predicate", "processID == \(pid)"]
    }

    /// Arguments for `log show` listing one process's messages from the last `seconds`.
    public static func showArguments(pid: Int32, level: Level, lastSeconds seconds: Int) -> [String] {
        var args = ["show", "--style", "ndjson", "--last", "\(max(1, seconds))s", "--predicate", "processID == \(pid)"]
        switch level {
        case .default: break
        case .info: args.append("--info")
        case .debug: args += ["--info", "--debug"]
        }
        return args
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    /// Parses one line of ndjson output; nil for anything else ("Filtering the log data…", the
    /// closing summary, or events other than messages).
    public static func parse(_ line: String, id: Int) -> LogEntry? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String else {
            return nil
        }
        let eventType = object["eventType"] as? String ?? ""
        guard eventType == "logEvent" || eventType == "activityCreateEvent" || eventType == "signpostEvent"
            || eventType == "stateEvent" || eventType == "userActionEvent" else {
            return nil
        }
        let messageType = object["messageType"] as? String ?? ""
        let type: String
        switch eventType {
        case "logEvent": type = messageType.isEmpty ? "Default" : messageType
        case "activityCreateEvent": type = "Activity"
        case "signpostEvent": type = "Signpost"
        case "stateEvent": type = "State"
        default: type = "User action"
        }
        // "2026-10-09 12:33:35.789327-0500": the time of day is characters 11 to 26.
        let chars = Array(timestamp)
        let time = chars.count >= 26 ? String(chars[11..<26]) : timestamp
        return LogEntry(
            id: id,
            date: timestampFormatter.date(from: timestamp) ?? Date(),
            time: time,
            type: type,
            subsystem: object["subsystem"] as? String ?? "",
            category: object["category"] as? String ?? "",
            message: object["eventMessage"] as? String ?? "",
            sender: ((object["senderImagePath"] as? String ?? "") as NSString).lastPathComponent,
            threadID: (object["threadID"] as? NSNumber)?.uint64Value ?? 0,
            processID: (object["processID"] as? NSNumber)?.int32Value ?? 0)
    }
}
