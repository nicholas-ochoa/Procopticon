import Darwin
import Foundation

/// Something that makes code run at login, at startup, on a schedule, or inside other processes:
/// what Autoruns lists on Windows and KnockKnock on the Mac. launchd jobs are in the Services tab.
public struct StartupItem: Identifiable, Hashable, Codable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case loginItems = "Login Items"
        case backgroundItems = "Background Items"
        case appExtensions = "App Extensions"
        case systemExtensions = "System Extensions"
        case kernelExtensions = "Kernel Extensions"
        case cron = "Cron Jobs"
        case periodic = "Periodic Scripts"
        case hooks = "Login & Logout Hooks"
        case authorization = "Authorization Plug-ins"
        case plugins = "Plug-ins"
        case profiles = "Configuration Profiles"
        case legacy = "Legacy Startup Items"

        public var help: String {
            switch self {
            case .loginItems: return "Apps and helpers that open at login (System Settings ▸ General ▸ Login Items & Extensions)"
            case .backgroundItems: return "Agents, daemons and background tasks registered with Background Task Management"
            case .appExtensions: return "Quick Look, Spotlight and Dock tile extensions apps registered"
            case .systemExtensions: return "Network, endpoint security and driver extensions (systemextensionsctl)"
            case .kernelExtensions: return "Third-party kernel extensions, installed or loaded"
            case .cron: return "Commands cron runs on a schedule"
            case .periodic: return "Scripts periodic runs daily, weekly or monthly"
            case .hooks: return "Scripts loginwindow runs as root at every login or logout"
            case .authorization: return "Code the login window and authorization dialogs load"
            case .plugins: return "Bundles that load into other processes: input methods, screen savers, Spotlight importers and more"
            case .profiles: return "Installed configuration profiles, which can manage settings and install certificates"
            case .legacy: return "Old-style /Library/StartupItems, still honored on some systems"
            }
        }
    }

    public var id: String
    public var category: Category
    public var name: String
    /// What kind of item it is within its category, e.g. "Legacy daemon" or "Network extension".
    public var kind: String
    /// The executable, bundle, script or property list.
    public var path: String?
    /// Enabled, disabled, allowed…
    public var status: String
    public var developer: String?
    public var teamIdentifier: String?
    public var identifier: String?
    /// Schedule, command line or other specifics.
    public var details: String = ""
    /// The app the item belongs to.
    public var parent: String?
    /// The user it runs for, if not everyone.
    public var user: String?
    public var lastUsed: Date?
}

public struct StartupItemsReport: Codable, Sendable {
    public var items: [StartupItem]
    /// Sources that couldn't be read, e.g. without root.
    public var warnings: [String]
}

public enum StartupItems {
    /// Collects every source. Run as root (the helper) to include other users' cron jobs and the
    /// login hooks.
    public static func collect() -> StartupItemsReport {
        var items: [StartupItem] = []
        var warnings: [String] = []
        let btm = ToolRunner.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 30)
        if btm.status == 0 {
            items += parseBTM(btm.stdout)
        } else {
            warnings.append("Login and background items: \(btm.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        items += parseSystemExtensions(ToolRunner.run("/usr/bin/systemextensionsctl", ["list"], timeout: 15).stdout)
        items += kernelExtensions(loaded: ToolRunner.run("/usr/bin/kmutil", ["showloaded", "--list-only"], timeout: 30).stdout)
        let (cron, cronWarning) = cronJobs()
        items += cron
        warnings += cronWarning.map { [$0] } ?? []
        items += periodicScripts()
        let (hooks, hookWarning) = loginHooks()
        items += hooks
        warnings += hookWarning.map { [$0] } ?? []
        items += bundles(in: ["/Library/Security/SecurityAgentPlugins"], category: .authorization, kind: "Authorization plug-in")
        items += pluginBundles()
        items += profiles(ToolRunner.run("/usr/bin/profiles", ["show", "-output", "stdout-xml"], timeout: 30).stdout)
        items += bundles(in: ["/Library/StartupItems"], category: .legacy, kind: "Startup item")
        return StartupItemsReport(items: items, warnings: warnings)
    }

    // MARK: Background Task Management

    /// Parses `sfltool dumpbtm`: per-user sections of numbered records of "Key: value" lines.
    static func parseBTM(_ text: String) -> [StartupItem] {
        struct Record {
            var uid: Int
            var fields: [String: String] = [:]
            var embedded: [String] = []
        }
        var records: [Record] = []
        var uid = 0
        var current: Record?
        var inEmbedded = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID "), let n = Int(line.dropFirst(16).prefix { $0 == "-" || $0.isNumber }) {
                if let r = current { records.append(r) }
                current = nil
                uid = n
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("#"), Int(key.dropFirst()) != nil {
                if value.isEmpty {
                    if let r = current { records.append(r) }
                    current = Record(uid: uid)
                    inEmbedded = false
                } else if inEmbedded {
                    current?.embedded.append(value)
                }
                continue
            }
            if key == "Embedded Item Identifiers" {
                inEmbedded = true
                continue
            }
            inEmbedded = false
            if current?.fields[key] == nil {
                current?.fields[key] = value
            }
        }
        if let r = current { records.append(r) }

        func null(_ s: String?) -> String? {
            guard let s, !s.isEmpty, s != "(null)" else { return nil }
            return s
        }
        let byIdentifier = Dictionary(records.compactMap { r in r.fields["Identifier"].map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"

        var items: [StartupItem] = []
        for r in records {
            let f = r.fields
            let typeText = f["Type"] ?? ""
            let typeName = typeText.components(separatedBy: " (").first ?? typeText
            let typeValue = typeText.range(of: "(0x").flatMap { UInt32(typeText[$0.upperBound...].prefix { $0.isHexDigit }, radix: 16) } ?? 0
            let category: StartupItem.Category
            if typeValue & 0x4 != 0 {
                category = .loginItems
            } else if typeValue & (0x8 | 0x10 | 0x2000) != 0 {
                category = .backgroundItems
            } else if typeValue & (0x40 | 0x80 | 0x800) != 0 {
                category = .appExtensions
            } else {
                // Apps and developers only group the items above.
                continue
            }
            let parentRecord = f["Parent Identifier"].flatMap { byIdentifier[$0] }
            var path = null(f["Executable Path"]) ?? null(f["URL"])
            if let p = path, !p.hasPrefix("/"), let base = null(parentRecord?.fields["URL"]) {
                path = (base as NSString).appendingPathComponent(p)
            }
            if let p = path, p.hasPrefix("file://") {
                path = URL(string: p)?.path
            }
            let disposition = f["Disposition"].map { d -> [String] in
                guard let open = d.firstIndex(of: "["), let close = d.firstIndex(of: "]") else { return [] }
                return d[d.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } ?? []
            var status = disposition.contains("enabled") ? "Enabled" : (disposition.contains("disabled") ? "Disabled" : "")
            if disposition.contains("disallowed") {
                status += status.isEmpty ? "Not allowed" : ", not allowed"
            }
            var details: [String] = []
            if let plist = null(f["URL"]), plist.hasSuffix(".plist") { details.append(plist) }
            if let flags = f["Flags"], let open = flags.firstIndex(of: "["), let close = flags.firstIndex(of: "]") {
                let words = flags[flags.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                if !words.isEmpty { details.append(words) }
            }
            let identifier = null(f["Bundle Identifier"]) ?? f["Identifier"].map { id -> String in
                // "16.sh.brew.nginx": the type, then the label or bundle identifier.
                guard let dot = id.firstIndex(of: "."), Int(id[..<dot]) != nil else { return id }
                return String(id[id.index(after: dot)...])
            }
            items.append(StartupItem(
                id: "btm:\(r.uid):\(f["UUID"] ?? UUID().uuidString)",
                category: category,
                name: null(f["Name"]) ?? identifier ?? "Unnamed",
                kind: btmKind(typeName),
                path: path,
                status: status,
                developer: null(f["Developer Name"]),
                teamIdentifier: null(f["Team Identifier"]),
                identifier: identifier,
                details: details.joined(separator: " · "),
                parent: null(parentRecord?.fields["Name"]),
                user: r.uid >= 0 ? UserNames.name(uid_t(r.uid)) : nil,
                lastUsed: f["Last Use"].flatMap { dateFormatter.date(from: $0) }))
        }
        return items
    }

    static func btmKind(_ type: String) -> String {
        switch type {
        case "quicklook": return "Quick Look extension"
        case "spotlight": return "Spotlight extension"
        case "dock tile": return "Dock tile plug-in"
        case "background tasks": return "Background task"
        default: return type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    // MARK: Extensions

    /// Parses `systemextensionsctl list`: a "--- category" line, a header, then tab-separated rows.
    static func parseSystemExtensions(_ text: String) -> [StartupItem] {
        var items: [StartupItem] = []
        var kind = "System extension"
        for line in text.split(separator: "\n") {
            if line.hasPrefix("--- ") {
                let raw = line.dropFirst(4).split(separator: ".").last.map(String.init) ?? ""
                kind = raw.replacingOccurrences(of: "_", with: " ").capitalized
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 6, fields[0] != "enabled" else { continue }
            let bundle = fields[3]
            let id = bundle.components(separatedBy: " (").first ?? bundle
            let version = bundle.range(of: "(").map { String(bundle[$0.upperBound...].dropLast()) }
            let state = fields[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            items.append(StartupItem(
                id: "sysext:\(id):\(fields[2])", category: .systemExtensions, name: fields[4], kind: kind, path: nil,
                status: state.isEmpty ? (fields[0] == "*" ? "Enabled" : "Disabled") : state.capitalized,
                developer: nil, teamIdentifier: fields[2].isEmpty ? nil : fields[2], identifier: id,
                details: [version.map { "Version \($0)" }, fields[1] == "*" ? "Active" : nil].compactMap { $0 }.joined(separator: " · ")))
        }
        return items
    }

    /// Third-party kernel extensions in /Library/Extensions, and any others loaded
    /// (`kmutil showloaded --list-only`).
    static func kernelExtensions(loaded text: String) -> [StartupItem] {
        var loaded: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 7, Int(fields[0]) != nil else { continue }
            let id = String(fields[5])
            guard !id.hasPrefix("com.apple.") else { continue }
            loaded[id] = String(fields[6]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        var items: [StartupItem] = []
        var seen = Set<String>()
        for path in contents(of: "/Library/Extensions") where path.hasSuffix(".kext") {
            let bundle = Bundle(path: path)
            let id = bundle?.bundleIdentifier ?? (path as NSString).lastPathComponent
            seen.insert(id)
            items.append(StartupItem(
                id: "kext:\(path)", category: .kernelExtensions, name: (path as NSString).lastPathComponent, kind: "Kernel extension",
                path: path, status: loaded[id] != nil ? "Loaded" : "Installed", developer: nil, teamIdentifier: nil,
                identifier: id, details: (bundle?.infoDictionary?["CFBundleShortVersionString"] as? String).map { "Version \($0)" } ?? ""))
        }
        for (id, version) in loaded where !seen.contains(id) {
            items.append(StartupItem(
                id: "kext:\(id)", category: .kernelExtensions, name: id, kind: "Kernel extension", path: nil,
                status: "Loaded", developer: nil, teamIdentifier: nil, identifier: id, details: "Version \(version)"))
        }
        return items
    }

    // MARK: Scheduled and login scripts

    static func cronJobs() -> ([StartupItem], String?) {
        var items: [StartupItem] = []
        var warning: String?
        if geteuid() == 0 {
            for path in contents(of: "/usr/lib/cron/tabs") {
                let user = (path as NSString).lastPathComponent
                items += parseCrontab((try? String(contentsOfFile: path, encoding: .utf8)) ?? "", user: user, source: path)
            }
        } else {
            let own = ToolRunner.run("/usr/bin/crontab", ["-l"], timeout: 10)
            if own.status == 0 {
                items += parseCrontab(own.stdout, user: UserNames.name(getuid()), source: "crontab -l")
            }
            warning = "Cron jobs: only yours are listed; show details for all processes to include every user's."
        }
        if let system = try? String(contentsOfFile: "/etc/crontab", encoding: .utf8) {
            items += parseCrontab(system, user: nil, source: "/etc/crontab", hasUserField: true)
        }
        return (items, warning)
    }

    /// One item per job line; environment settings and comments are skipped.
    static func parseCrontab(_ text: String, user: String?, source: String, hasUserField: Bool = false) -> [StartupItem] {
        var items: [StartupItem] = []
        for (index, raw) in text.split(separator: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let first = fields.first else { continue }
            if first.contains("="), !first.hasPrefix("@") { continue }
            let scheduleCount = first.hasPrefix("@") ? 1 : 5
            guard fields.count > scheduleCount + (hasUserField ? 1 : 0) else { continue }
            let schedule = fields.prefix(scheduleCount).joined(separator: " ")
            var rest = Array(fields.dropFirst(scheduleCount))
            var runAs = user
            if hasUserField {
                runAs = rest.removeFirst()
            }
            let command = rest.joined(separator: " ")
            let executable = command.split(separator: " ").first.map(String.init)
            items.append(StartupItem(
                id: "cron:\(source):\(index)", category: .cron, name: command, kind: "Cron job",
                path: executable.flatMap { $0.hasPrefix("/") ? $0 : nil }, status: "Scheduled", developer: nil,
                teamIdentifier: nil, identifier: nil, details: "\(schedule) — from \(source)", user: runAs))
        }
        return items
    }

    static func periodicScripts() -> [StartupItem] {
        var items: [StartupItem] = []
        for base in ["/etc/periodic", "/usr/local/etc/periodic"] {
            for dir in contents(of: base) {
                for script in contents(of: dir) {
                    items.append(StartupItem(
                        id: "periodic:\(script)", category: .periodic, name: (script as NSString).lastPathComponent,
                        kind: "\((dir as NSString).lastPathComponent.capitalized) script", path: script, status: "Scheduled",
                        developer: nil, teamIdentifier: nil, identifier: nil))
                }
            }
        }
        for name in ["daily", "weekly", "monthly"] {
            let path = "/etc/\(name).local"
            if FileManager.default.fileExists(atPath: path) {
                items.append(StartupItem(id: "periodic:\(path)", category: .periodic, name: "\(name).local", kind: "\(name.capitalized) script",
                                         path: path, status: "Scheduled", developer: nil, teamIdentifier: nil, identifier: nil))
            }
        }
        return items
    }

    static func loginHooks() -> ([StartupItem], String?) {
        var items: [StartupItem] = []
        var unreadable = false
        for path in ["/var/root/Library/Preferences/com.apple.loginwindow.plist", "/Library/Preferences/com.apple.loginwindow.plist"] {
            guard FileManager.default.isReadableFile(atPath: path) else {
                // root's preferences can't even be checked for without root.
                if path.hasPrefix("/var/root") { unreadable = true }
                continue
            }
            guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            for key in ["LoginHook", "LogoutHook"] {
                if let script = dict[key] as? String, !script.isEmpty {
                    items.append(StartupItem(
                        id: "hook:\(path):\(key)", category: .hooks, name: (script as NSString).lastPathComponent,
                        kind: key == "LoginHook" ? "Login hook" : "Logout hook", path: script, status: "Enabled",
                        developer: nil, teamIdentifier: nil, identifier: nil, details: "Set in \(path)", user: "root"))
                }
            }
        }
        let warning = unreadable && geteuid() != 0
            ? "Login & logout hooks: root's settings are only readable with details for all processes shown." : nil
        return (items, warning)
    }

    // MARK: Bundles

    static func pluginBundles() -> [StartupItem] {
        let home = UserNames.home(Elevation.interactiveUid) ?? NSHomeDirectory()
        let folders: [(String, String)] = [
            ("Input Methods", "Input method"), ("Screen Savers", "Screen saver"), ("Spotlight", "Spotlight importer"),
            ("QuickLook", "Quick Look generator"), ("PreferencePanes", "Preference pane"), ("ScriptingAdditions", "Scripting addition"),
            ("Internet Plug-Ins", "Internet plug-in"), ("Audio/Plug-Ins/HAL", "Audio driver"), ("CoreMediaIO/Plug-Ins/DAL", "Camera plug-in"),
            ("DirectoryServices/PlugIns", "Directory services plug-in"), ("Contextual Menu Items", "Contextual menu item"),
        ]
        var items: [StartupItem] = []
        for (folder, kind) in folders {
            items += bundles(in: ["/Library/" + folder, home + "/Library/" + folder], category: .plugins, kind: kind)
        }
        return items
    }

    static func bundles(in folders: [String], category: StartupItem.Category, kind: String) -> [StartupItem] {
        var items: [StartupItem] = []
        for folder in folders {
            for path in contents(of: folder) where !(path as NSString).lastPathComponent.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                      !(path as NSString).pathExtension.isEmpty else { continue }
                let bundle = Bundle(path: path)
                let info = bundle?.infoDictionary ?? [:]
                let version = info["CFBundleShortVersionString"] as? String
                items.append(StartupItem(
                    id: "bundle:\(path)", category: category, name: (path as NSString).lastPathComponent, kind: kind,
                    path: bundle?.executablePath ?? path, status: "Installed", developer: nil, teamIdentifier: nil,
                    identifier: bundle?.bundleIdentifier, details: version.map { "Version \($0)" } ?? "",
                    user: folder.hasPrefix("/Library") ? nil : UserNames.name(Elevation.interactiveUid)))
            }
        }
        return items
    }

    // MARK: Profiles

    /// Parses `profiles show -output stdout-xml`: scopes ("_computerlevel" or a user name) mapped to
    /// lists of profiles.
    static func profiles(_ xml: String) -> [StartupItem] {
        guard let data = xml.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var items: [StartupItem] = []
        for (scope, value) in root {
            for p in value as? [[String: Any]] ?? [] {
                let id = p["ProfileIdentifier"] as? String ?? UUID().uuidString
                let payloads = (p["ProfileItems"] as? [[String: Any]] ?? []).compactMap { $0["PayloadType"] as? String }
                var details = Set(payloads).sorted().joined(separator: ", ")
                if let date = p["ProfileInstallDate"] {
                    details = "Installed \(date)" + (details.isEmpty ? "" : " · \(details)")
                }
                items.append(StartupItem(
                    id: "profile:\(scope):\(id)", category: .profiles, name: p["ProfileDisplayName"] as? String ?? id,
                    kind: scope == "_computerlevel" ? "Device profile" : "User profile", path: nil, status: "Installed",
                    developer: p["ProfileOrganization"] as? String, teamIdentifier: nil, identifier: id, details: details,
                    user: scope == "_computerlevel" ? nil : scope))
            }
        }
        return items
    }

    private static func contents(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().map { folder + "/" + $0 }
    }
}
