import Darwin
import Foundation

/// Metadata about the bundle (app, extension, XPC service, framework) containing an executable.
public struct ExecutableBundleInfo: Sendable {
    public var bundlePath: String?
    public var bundleIdentifier: String?
    public var displayName: String?
    public var version: String?
    public var build: String?
    public var copyright: String?
    public var minimumSystemVersion: String?
    public var isApplication: Bool
    /// The executable is the bundle's own (CFBundleExecutable), not a helper tool inside it.
    public var isMainExecutable = false
    public var fileSize: UInt64?
    public var fileModified: Date?
    public var fileCreated: Date?
    /// Where the executable (or its app) was downloaded from, if it's quarantined.
    public var quarantine: QuarantineInfo?

    public var versionString: String {
        switch (version, build) {
        case let (v?, b?) where v != b: return "\(v) (\(b))"
        case let (v?, _): return v
        case let (nil, b?): return b
        default: return ""
        }
    }
}

public final class BundleInfoCache: @unchecked Sendable {
    public static let shared = BundleInfoCache()
    private let lock = NSLock()
    private var cache: [String: ExecutableBundleInfo] = [:]

    public func info(for executablePath: String) -> ExecutableBundleInfo {
        lock.lock()
        if let c = cache[executablePath] {
            lock.unlock()
            return c
        }
        lock.unlock()
        let info = Self.load(executablePath)
        lock.lock()
        cache[executablePath] = info
        lock.unlock()
        return info
    }

    static let bundleExtensions: Set<String> = ["app", "appex", "xpc", "framework", "bundle", "plugin", "kext", "systemextension", "dext", "prefPane", "saver", "qlgenerator", "mdimporter"]

    /// Walks up from an executable to the innermost enclosing bundle directory.
    /// String operations only: building file URLs `lstat`s the path, and icons call this for every
    /// visible row on each refresh.
    public static func enclosingBundlePath(_ executablePath: String) -> String? {
        var path = executablePath as NSString
        for _ in 0..<8 {
            path = path.deletingLastPathComponent as NSString
            if path.length <= 1 { return nil }
            if bundleExtensions.contains(path.pathExtension) {
                return path as String
            }
        }
        return nil
    }

    /// Outermost enclosing .app (for icons/"open application").
    public static func outermostApplicationPath(_ executablePath: String) -> String? {
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        var path = ""
        for c in components {
            path += "/" + c
            if c.hasSuffix(".app") {
                return path
            }
        }
        return nil
    }

    static func load(_ executablePath: String) -> ExecutableBundleInfo {
        var info = ExecutableBundleInfo(isApplication: false)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: executablePath) {
            info.fileSize = (attrs[.size] as? NSNumber)?.uint64Value
            info.fileModified = attrs[.modificationDate] as? Date
            info.fileCreated = attrs[.creationDate] as? Date
        }
        info.quarantine = Quarantine.info(forExecutable: executablePath)
        guard let bundlePath = enclosingBundlePath(executablePath), let bundle = Bundle(path: bundlePath) else {
            // Command line tools may embed an Info.plist section; Bundle can't read it, so fall back.
            return info
        }
        let dict = bundle.infoDictionary ?? [:]
        let localized = bundle.localizedInfoDictionary ?? [:]
        info.bundlePath = bundlePath
        info.bundleIdentifier = bundle.bundleIdentifier
        info.displayName = (localized["CFBundleDisplayName"] ?? dict["CFBundleDisplayName"] ?? localized["CFBundleName"] ?? dict["CFBundleName"]) as? String
        info.version = dict["CFBundleShortVersionString"] as? String
        info.build = dict["CFBundleVersion"] as? String
        info.copyright = (localized["NSHumanReadableCopyright"] ?? dict["NSHumanReadableCopyright"]) as? String
        info.minimumSystemVersion = dict["LSMinimumSystemVersion"] as? String
        info.isApplication = bundlePath.hasSuffix(".app")
        if let main = bundle.executablePath {
            info.isMainExecutable = main.caseInsensitiveCompare(executablePath) == .orderedSame
        }
        return info
    }
}

/// uid/gid → name lookups with caching.
public enum UserNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var users: [uid_t: String] = [:]
    nonisolated(unsafe) private static var fullNames: [uid_t: String] = [:]
    nonisolated(unsafe) private static var groups: [gid_t: String] = [:]

    public static func name(_ uid: uid_t) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let n = users[uid] { return n }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buf = [CChar](repeating: 0, count: 4096)
        var name = "\(uid)"
        var full = ""
        if getpwuid_r(uid, &pwd, &buf, buf.count, &result) == 0, result != nil {
            name = String(cString: pwd.pw_name)
            full = String(cString: pwd.pw_gecos)
        }
        users[uid] = name
        fullNames[uid] = full
        return name
    }

    public static func fullName(_ uid: uid_t) -> String {
        _ = name(uid)
        lock.lock()
        defer { lock.unlock() }
        return fullNames[uid] ?? ""
    }

    public static func group(_ gid: gid_t) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let n = groups[gid] { return n }
        var grp = Darwin.group()
        var result: UnsafeMutablePointer<Darwin.group>?
        var buf = [CChar](repeating: 0, count: 8192)
        var name = "\(gid)"
        if getgrgid_r(gid, &grp, &buf, buf.count, &result) == 0, result != nil {
            name = String(cString: grp.gr_name)
        }
        groups[gid] = name
        return name
    }

    /// Group membership of a user (by name).
    public static func groupList(for uid: uid_t) -> [String] {
        let user = name(uid)
        var count: Int32 = 64
        var gids = [Int32](repeating: 0, count: Int(count))
        let basegid = Int32(bitPattern: primaryGroup(uid))
        if getgrouplist(user, basegid, &gids, &count) == -1 {
            gids = [Int32](repeating: 0, count: 1024)
            count = 1024
            getgrouplist(user, basegid, &gids, &count)
        }
        return gids.prefix(Int(max(0, count))).map { group(gid_t(bitPattern: $0)) }
    }

    public static func primaryGroup(_ uid: uid_t) -> gid_t {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buf = [CChar](repeating: 0, count: 4096)
        if getpwuid_r(uid, &pwd, &buf, buf.count, &result) == 0, result != nil {
            return pwd.pw_gid
        }
        return 0
    }

    public static func home(_ uid: uid_t) -> String? {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buf = [CChar](repeating: 0, count: 4096)
        if getpwuid_r(uid, &pwd, &buf, buf.count, &result) == 0, result != nil {
            return String(cString: pwd.pw_dir)
        }
        return nil
    }
}

/// Logged-in sessions from utmpx.
public struct LoginSession: Identifiable, Sendable, Hashable {
    public var id: String { "\(user)-\(line)-\(pid)" }
    public var user: String
    public var line: String
    public var host: String
    public var pid: Int32
    public var loginTime: Date

    public static func current() -> [LoginSession] {
        var result: [LoginSession] = []
        setutxent()
        while let entry = getutxent() {
            let e = entry.pointee
            guard e.ut_type == USER_PROCESS else { continue }
            func str<T>(_ t: T) -> String {
                withUnsafeBytes(of: t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            result.append(LoginSession(
                user: str(e.ut_user), line: str(e.ut_line), host: str(e.ut_host), pid: e.ut_pid,
                loginTime: Date(timeIntervalSince1970: Double(e.ut_tv.tv_sec))))
        }
        endutxent()
        return result
    }
}
