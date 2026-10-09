import Darwin
import Foundation
import SQLite3

/// Where a downloaded file came from: its quarantine flag (`com.apple.quarantine`), the URLs Safari,
/// Chrome and others record (`kMDItemWhereFroms`), and the matching LaunchServices quarantine event.
public struct QuarantineInfo: Hashable, Sendable {
    /// Bits of the flag (see `isApproved`).
    public var flags: UInt32
    /// The app that downloaded or created the file, e.g. "Safari", "Chrome", "Homebrew Cask".
    public var agent: String?
    public var agentBundleIdentifier: String?
    public var date: Date?
    public var eventIdentifier: String?
    /// The file's own URL, when known.
    public var downloadURL: String?
    /// The page it was downloaded from, when known.
    public var pageURL: String?

    /// The user approved opening it (Gatekeeper's "Are you sure you want to open it?").
    public var isApproved: Bool { flags & 0x0040 != 0 }
    /// It was created by a sandboxed app rather than downloaded.
    public var isFromSandbox: Bool { flags & 0x0002 != 0 }

    /// "Downloaded with Chrome on 2 Oct 2026", or as close as what was recorded allows.
    public var sourceDescription: String {
        var text = isFromSandbox ? "Created by a sandboxed app" : "Downloaded"
        if let agent, !agent.isEmpty {
            text += isFromSandbox ? " (\(agent))" : " with \(agent)"
        }
        if let date {
            text += " on " + date.formatted(date: .abbreviated, time: .shortened)
        }
        return text
    }

    /// The first URL known, for a single column.
    public var url: String? { downloadURL ?? pageURL }
}

public enum Quarantine {
    /// Quarantine information for an executable: its outermost app bundle's (where the flag of an
    /// app is set and checked), else the executable's own. Nil when neither is quarantined.
    public static func info(forExecutable path: String) -> QuarantineInfo? {
        if let app = BundleInfoCache.outermostApplicationPath(path), let info = info(path: app) {
            return info
        }
        return info(path: path)
    }

    /// Quarantine information for one file or bundle, or nil if it has no quarantine flag.
    public static func info(path: String) -> QuarantineInfo? {
        guard let raw = attribute("com.apple.quarantine", path: path).map({ String(decoding: $0, as: UTF8.self) }) else {
            return nil
        }
        var info = parse(raw)
        if let froms = attribute("com.apple.metadata:kMDItemWhereFroms", path: path),
           let urls = try? PropertyListSerialization.propertyList(from: froms, format: nil) as? [String] {
            info.downloadURL = urls.first.flatMap { $0.isEmpty ? nil : $0 }
            info.pageURL = urls.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let id = info.eventIdentifier, let event = QuarantineEvents.event(id) {
            info.agent = info.agent ?? event.agent
            info.agentBundleIdentifier = event.agentBundleIdentifier
            info.downloadURL = info.downloadURL ?? event.dataURL
            info.pageURL = info.pageURL ?? event.originURL
            info.date = info.date ?? event.date
        }
        return info
    }

    /// "flags;hex seconds since 1970;agent;event UUID".
    static func parse(_ raw: String) -> QuarantineInfo {
        let fields = raw.trimmingCharacters(in: .controlCharacters).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        func field(_ i: Int) -> String? {
            guard fields.indices.contains(i), !fields[i].isEmpty else { return nil }
            return fields[i]
        }
        return QuarantineInfo(
            flags: field(0).flatMap { UInt32($0, radix: 16) } ?? 0,
            agent: field(2),
            date: field(1).flatMap { UInt64($0, radix: 16) }.map { Date(timeIntervalSince1970: Double($0)) },
            eventIdentifier: field(3))
    }

    private static func attribute(_ name: String, path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read > 0 ? data.prefix(read) : nil
    }
}

/// LaunchServices' record of downloads (~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2).
enum QuarantineEvents {
    struct Event {
        var agent: String?
        var agentBundleIdentifier: String?
        var dataURL: String?
        var originURL: String?
        var date: Date?
    }

    /// The interactive user's database, even when running as root.
    static var databasePath: String {
        let home = UserNames.home(Elevation.interactiveUid) ?? NSHomeDirectory()
        return home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
    }

    static func event(_ identifier: String) -> Event? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT LSQuarantineAgentName, LSQuarantineAgentBundleIdentifier, LSQuarantineDataURLString,
                   LSQuarantineOriginURLString, LSQuarantineTimeStamp
            FROM LSQuarantineEvent WHERE LSQuarantineEventIdentifier = ?1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, identifier, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ column: Int32) -> String? {
            guard let c = sqlite3_column_text(statement, column) else { return nil }
            let s = String(cString: c)
            return s.isEmpty ? nil : s
        }
        let seconds = sqlite3_column_double(statement, 4)
        return Event(agent: text(0), agentBundleIdentifier: text(1), dataURL: text(2), originURL: text(3),
                     date: seconds > 0 ? Date(timeIntervalSinceReferenceDate: seconds) : nil)
    }
}
