import Foundation

/// A crash or diagnostic report from ~/Library/Logs/DiagnosticReports or
/// /Library/Logs/DiagnosticReports (what Console lists under Crash Reports, Spin Reports, …).
public struct DiagnosticReport: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case crash = "Crash"
        case exception = "Exception"
        case hang = "Hang"
        case cpu = "CPU usage"
        case diskWrites = "Disk writes"
        case wakeups = "Wake-ups"
        case memory = "Memory (jetsam)"
        case panic = "Kernel panic"
        case shutdownStall = "Shutdown stall"
        case other = "Other"

        /// Reports of a process ending abnormally, as opposed to using too much of something.
        public var isCrash: Bool { self == .crash || self == .panic }
        public var isResourceReport: Bool { self == .cpu || self == .diskWrites || self == .wakeups }
    }

    public var id: String { path }
    public var path: String
    public var kind: Kind
    /// The process the report is about (for a jetsam report, the processes it killed).
    public var processName: String
    public var date: Date
    public var bundleIdentifier: String?
    public var executablePath: String?
    public var version: String?
    public var pid: Int32?
    /// The exception and signal of a crash, or the event of a resource report.
    public var summary: String
    /// Every process a jetsam report says was killed.
    public var killedProcesses: [String] = []
    /// Moved to the Retired folder once submitted or aged out.
    public var isRetired: Bool

    public var fileName: String { (path as NSString).lastPathComponent }

    /// Whether the report is about the process with this executable path, name and bundle ID.
    public func concerns(path: String?, name: String, bundleIdentifier: String?) -> Bool {
        if let path, let executablePath, executablePath == path { return true }
        if let bundleIdentifier, let mine = self.bundleIdentifier, mine == bundleIdentifier { return true }
        if processName == name || killedProcesses.contains(name) { return true }
        return false
    }
}

public enum DiagnosticReports {
    public static var folders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]
    }

    static let extensions: Set<String> = ["ips", "diag", "crash", "hang", "spin", "panic", "shutdownStall"]

    private static let cacheLock = NSLock()
    /// Parsed reports by path, with the modification date they were parsed at.
    nonisolated(unsafe) private static var cache: [String: (modified: Date, report: DiagnosticReport?)] = [:]

    /// Every report readable in the report folders and their Retired subfolders, newest first.
    /// Files already read are only read again when they change.
    public static func all() -> [DiagnosticReport] {
        var reports: [DiagnosticReport] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for folder in folders {
            for (dir, retired) in [(folder, false), (folder + "/Retired", true)] {
                guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in names where !name.hasPrefix(".") && extensions.contains((name as NSString).pathExtension) {
                    let path = dir + "/" + name
                    seen.insert(path)
                    let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    let cached = cacheLock.withLock { cache[path] }
                    if let cached, cached.modified == modified {
                        if let r = cached.report { reports.append(r) }
                        continue
                    }
                    let r = read(path: path, retired: retired)
                    cacheLock.withLock { cache[path] = (modified, r) }
                    if let r { reports.append(r) }
                }
            }
        }
        cacheLock.withLock { cache = cache.filter { seen.contains($0.key) } }
        return reports.sorted { $0.date > $1.date }
    }

    public static func read(path: String, retired: Bool = false) -> DiagnosticReport? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        if path.hasSuffix(".ips") {
            return parseIPS(text, path: path, retired: retired, fallbackDate: modified)
        }
        return parseText(text, path: path, retired: retired, fallbackDate: modified)
    }

    private static let ipsDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return f
    }()

    private static let diagDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return f
    }()

    /// `.ips`: a one-line JSON header, then the report as JSON.
    static func parseIPS(_ text: String, path: String, retired: Bool, fallbackDate: Date) -> DiagnosticReport? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let headerLine = parts.first,
              let header = try? JSONSerialization.jsonObject(with: Data(headerLine.utf8)) as? [String: Any] else {
            return nil
        }
        let body = parts.count > 1 ? (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any]) ?? [:] : [:]
        let bugType = header["bug_type"] as? String ?? body["bug_type"] as? String ?? ""
        let fileName = (path as NSString).lastPathComponent
        var name = header["app_name"] as? String ?? header["name"] as? String ?? body["procName"] as? String ?? ""
        var kind: DiagnosticReport.Kind
        switch bugType {
        case "309", "109": kind = fileName.hasPrefix("ExcUserFault_") ? .exception : .crash
        case "298": kind = .memory
        case "210": kind = .panic
        case "288", "409": kind = .hang
        default: kind = .other
        }
        var summary = ""
        var killed: [String] = []
        if let exception = body["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? ""
            let signal = exception["signal"] as? String
            summary = signal.map { "\(type) (\($0))" } ?? type
            if let subtype = exception["subtype"] as? String, !subtype.isEmpty {
                summary += " — \(subtype)"
            }
        }
        if kind == .memory {
            let processes = body["processes"] as? [[String: Any]] ?? []
            for p in processes where p["reason"] != nil {
                if let n = p["name"] as? String { killed.append(n) }
            }
            let reasons = Set(processes.compactMap { $0["reason"] as? String })
            summary = killed.isEmpty ? "No process killed" : "Killed \(killed.count): \(killed.prefix(4).joined(separator: ", "))\(killed.count > 4 ? "…" : "")"
            if !reasons.isEmpty { summary += " (\(reasons.sorted().joined(separator: ", ")))" }
            if name.isEmpty { name = "JetsamEvent" }
        }
        if name.isEmpty {
            name = fileName.components(separatedBy: "-").first ?? fileName
        }
        let bundle = body["bundleInfo"] as? [String: Any]
        let version = [header["app_version"] as? String ?? bundle?["CFBundleShortVersionString"] as? String,
                       header["build_version"] as? String ?? bundle?["CFBundleVersion"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let date = (header["timestamp"] as? String).flatMap { ipsDate.date(from: $0) } ?? fallbackDate
        return DiagnosticReport(
            path: path, kind: kind, processName: name, date: date,
            bundleIdentifier: header["bundleID"] as? String ?? bundle?["CFBundleIdentifier"] as? String,
            executablePath: body["procPath"] as? String,
            version: version.isEmpty ? nil : (version.count == 2 && version[0] != version[1] ? "\(version[0]) (\(version[1]))" : version[0]),
            pid: (body["pid"] as? NSNumber)?.int32Value,
            summary: summary, killedProcesses: killed, isRetired: retired)
    }

    /// `.diag` and other text reports: "Key:   value" lines at the top.
    static func parseText(_ text: String, path: String, retired: Bool, fallbackDate: Date) -> DiagnosticReport? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(60) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains("  "), fields[key] == nil else { continue }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let fileName = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension
        let event = fields["Event"] ?? ""
        let kind: DiagnosticReport.Kind
        switch (ext, event.lowercased()) {
        case (_, "cpu usage"): kind = .cpu
        case (_, "disk writes"): kind = .diskWrites
        case (_, "wakeups"), (_, "wake-ups"): kind = .wakeups
        case (_, "hang"), (_, "spin"), ("hang", _), ("spin", _): kind = .hang
        case ("crash", _): kind = .crash
        case ("panic", _): kind = .panic
        case ("shutdownStall", _): kind = .shutdownStall
        default: kind = .other
        }
        var summary = event
        if let limit = fields["Action taken"], !limit.isEmpty, limit != "none" {
            summary += " — \(limit)"
        }
        if kind == .crash, let type = fields["Exception Type"] {
            summary = type
        }
        let date = (fields["Date/Time"]).flatMap { diagDate.date(from: $0) } ?? fallbackDate
        let command = fields["Command"] ?? fields["Process"]?.components(separatedBy: " [").first
        let name = command ?? fileName.components(separatedBy: "_").first ?? fileName
        return DiagnosticReport(
            path: path, kind: kind, processName: name, date: date,
            bundleIdentifier: fields["Identifier"], executablePath: fields["Path"],
            version: fields["Version"], pid: fields["PID"].flatMap { Int32($0) },
            summary: summary, isRetired: retired)
    }

    // MARK: Readable crash reports

    /// The report as text. A JSON crash report is laid out like the crash logs of old: the process,
    /// the exception, and every thread's backtrace with the crashed one first, then the libraries.
    public static func readableText(path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            return "Unable to read \(path)."
        }
        let text = String(decoding: data, as: UTF8.self)
        guard path.hasSuffix(".ips") else { return text }
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
              body["threads"] != nil else {
            return text
        }
        return formatCrash(body)
    }

    static func formatCrash(_ d: [String: Any]) -> String {
        var out: [String] = []
        func line(_ label: String, _ value: Any?) {
            guard let value, "\(value)" != "" else { return }
            out.append(label.padding(toLength: 18, withPad: " ", startingAt: 0) + "\(value)")
        }
        let images = d["usedImages"] as? [[String: Any]] ?? []
        let bundle = d["bundleInfo"] as? [String: Any]
        line("Process:", "\(d["procName"] ?? "") [\(d["pid"] ?? "")]")
        line("Path:", d["procPath"])
        line("Identifier:", bundle?["CFBundleIdentifier"] ?? d["codeSigningID"])
        if let v = bundle?["CFBundleShortVersionString"] {
            line("Version:", "\(v) (\(bundle?["CFBundleVersion"] ?? ""))")
        }
        line("Code type:", d["cpuType"])
        line("Parent process:", "\(d["parentProc"] ?? "") [\(d["parentPid"] ?? "")]")
        if let r = d["responsibleProc"] {
            line("Responsible:", "\(r) [\(d["responsiblePid"] ?? "")]")
        }
        line("User ID:", d["userID"])
        out.append("")
        line("Date/Time:", d["captureTime"])
        line("Launch time:", d["procLaunch"])
        if let os = d["osVersion"] as? [String: Any] {
            line("OS version:", "\(os["train"] ?? "") (\(os["build"] ?? ""))")
        }
        line("Incident:", d["incident"])
        out.append("")
        if let e = d["exception"] as? [String: Any] {
            line("Exception type:", "\(e["type"] ?? "")\(e["signal"].map { " (\($0))" } ?? "")")
            line("Exception codes:", e["codes"])
            line("Exception subtype:", e["subtype"])
            line("Exception message:", e["message"])
        }
        if let t = d["termination"] as? [String: Any] {
            line("Termination:", "Namespace \(t["namespace"] ?? ""), Code \(t["code"] ?? "") \(t["indicator"] ?? "")")
            if let by = t["byProc"] {
                line("Terminated by:", "\(by) [\(t["byPid"] ?? "")]")
            }
            if let reasons = t["reasons"] as? [String] {
                line("Reasons:", reasons.joined(separator: "; "))
            }
        }
        if let asi = d["asi"] as? [String: [String]] {
            out.append("")
            out.append("Application Specific Information:")
            for (key, values) in asi.sorted(by: { $0.key < $1.key }) {
                values.forEach { out.append("\(key): \($0)") }
            }
        }
        if let backtraces = d["asiBacktraces"] as? [String], !backtraces.isEmpty {
            out.append("")
            out.append("Application Specific Backtrace:")
            out.append(contentsOf: backtraces)
        }
        if let last = d["lastExceptionBacktrace"] as? [[String: Any]], !last.isEmpty {
            out.append("")
            out.append("Last Exception Backtrace:")
            out.append(contentsOf: frames(last, images: images))
        }
        let threads = d["threads"] as? [[String: Any]] ?? []
        let faulting = (d["faultingThread"] as? NSNumber)?.intValue
        // The crashed thread first, then the rest in order.
        let order = threads.indices.sorted { a, b in (a == faulting ? -1 : a) < (b == faulting ? -1 : b) }
        for index in order {
            let t = threads[index]
            var title = "Thread \(index)"
            if index == faulting { title += " Crashed" }
            title += ":"
            if let name = t["name"] as? String { title += ": \(name)" }
            if let queue = t["queue"] as? String { title += "  Dispatch queue: \(queue)" }
            out.append("")
            out.append(title)
            out.append(contentsOf: frames(t["frames"] as? [[String: Any]] ?? [], images: images))
        }
        if !images.isEmpty {
            out.append("")
            out.append("Binary Images:")
            for image in images {
                let base = (image["base"] as? NSNumber)?.uint64Value ?? 0
                let size = (image["size"] as? NSNumber)?.uint64Value ?? 0
                let name = image["name"] as? String ?? "???"
                let version = image["CFBundleShortVersionString"].map { " (\($0))" } ?? ""
                out.append(String(format: "0x%llx - 0x%llx ", base, base + max(size, 1) - 1)
                           + "\(name)\(version) <\(image["uuid"] ?? "")> \(image["path"] ?? "")")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func frames(_ frames: [[String: Any]], images: [[String: Any]]) -> [String] {
        frames.enumerated().map { i, f in
            let imageIndex = (f["imageIndex"] as? NSNumber)?.intValue ?? -1
            let image = images.indices.contains(imageIndex) ? images[imageIndex] : [:]
            let name = image["name"] as? String ?? "???"
            let base = (image["base"] as? NSNumber)?.uint64Value ?? 0
            let offset = (f["imageOffset"] as? NSNumber)?.uint64Value ?? 0
            var location = String(format: "0x%016llx ", base &+ offset)
            if let symbol = f["symbol"] as? String {
                location += "\(symbol) + \(f["symbolLocation"] ?? 0)"
            } else {
                location += "\(name) + \(offset)"
            }
            if let file = f["sourceFile"] as? String {
                location += " (\(file):\(f["sourceLine"] ?? ""))"
            }
            return "\(String(i).padding(toLength: 4, withPad: " ", startingAt: 0))\(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(location)"
        }
    }
}
