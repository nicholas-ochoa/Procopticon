import CSysInfo
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
    /// How the item is turned off and on again, if it can be.
    public var toggle: Toggle?
    /// How the item is removed, if it can be.
    public var removal: Removal?
    /// Whether it's turned on, for items that can be toggled.
    public var isEnabled: Bool?

    /// What turning an item off does; see `StartupItems.perform`.
    public enum Toggle: Codable, Hashable, Sendable {
        /// `launchctl disable` keeps a launchd job (an agent, daemon or login item) from loading.
        case launchd(domain: String, label: String)
        /// `pluginkit -e ignore` turns an app extension off for the user.
        case appExtension(identifier: String)
        /// A cron job is commented out with a marker; `user` is nil for /etc/crontab.
        case cron(user: String?, line: String)
        /// periodic only runs scripts that are executable.
        case executable(path: String)
        /// An Open at Login app: turning it off takes it off the list (Open at Login has no switch)
        /// and remembers it, so it stays listed and can be put back.
        case openAtLogin(path: String, name: String, hidden: Bool)
    }

    public enum Removal: Codable, Hashable, Sendable {
        /// Unloads the job and moves its property list to the Trash.
        case launchdPlist(domain: String, label: String, plist: String)
        case cron(user: String?, line: String)
        /// Moves a bundle or script to the Trash.
        case trash(path: String)
        /// Deletes loginwindow's LoginHook or LogoutHook setting.
        case hook(plist: String, key: String)
        /// `profiles remove`.
        case profile(identifier: String, user: String?)
        /// Takes an app off Open at Login (and forgets it if it was turned off here).
        case openAtLogin(path: String, name: String)
    }
}

/// A change to a startup item, run with the privileges it needs (see `StartupItems.runsAsUser`).
public enum StartupAction: Codable, Sendable {
    case setEnabled(StartupItem.Toggle, Bool)
    case remove(StartupItem.Removal)
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
        applyLaunchdOverrides(&items)
        return StartupItemsReport(items: items, warnings: warnings)
    }

    /// Marks the launchd items `launchctl disable` turned off. The users' domains need root, except
    /// one's own.
    static func applyLaunchdOverrides(_ items: inout [StartupItem]) {
        var domains = Set<String>()
        for item in items {
            if case .launchd(let domain, _)? = item.toggle { domains.insert(domain) }
        }
        var disabled: [String: Set<String>] = [:]
        for domain in domains {
            disabled[domain] = parseDisabled(ToolRunner.run("/bin/launchctl", ["print-disabled", domain], timeout: 10).stdout)
        }
        for i in items.indices {
            guard case .launchd(let domain, let label)? = items[i].toggle else { continue }
            let off = disabled[domain]?.contains(label) == true
            items[i].isEnabled = !off
            if off {
                items[i].status = items[i].status.isEmpty ? "Disabled" : "Disabled (\(items[i].status.lowercased()))"
            }
        }
    }

    // MARK: Open at Login

    /// Where the Open at Login apps turned off here are remembered (path, name, hidden).
    static let disabledLoginAppsKey = "StartupItems.disabledOpenAtLogin"

    private static var disabledLoginApps: [[String: Any]] {
        get { UserDefaults.standard.array(forKey: disabledLoginAppsKey) as? [[String: Any]] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: disabledLoginAppsKey) }
    }

    /// Adds the user's Open at Login apps (System Settings ▸ General ▸ Login Items), and those
    /// turned off here. Run as the user: the list is per user.
    public static func addOpenAtLoginItems(_ items: inout [StartupItem]) {
        var list: UnsafeMutablePointer<si_login_item>?
        let n = si_login_items(&list)
        defer { free(list) }
        let me = UserNames.name(getuid())
        var listed = Set<String>()
        func item(name: String, path: String, hidden: Bool, enabled: Bool) -> StartupItem {
            let found = !path.isEmpty
            return StartupItem(
                id: "openAtLogin:\(found ? path : name)", category: .loginItems, name: name, kind: "Open at Login app",
                path: found ? path : nil, status: enabled ? (found ? "Enabled" : "Enabled, app not found") : "Disabled",
                developer: nil, teamIdentifier: nil,
                identifier: found ? Bundle(path: path)?.bundleIdentifier : nil,
                details: hidden ? "Opens hidden" : "", user: me,
                // An app that can't be found can't be put back, so it can only be removed.
                toggle: found ? .openAtLogin(path: path, name: name, hidden: hidden) : nil,
                removal: .openAtLogin(path: path, name: name), isEnabled: enabled)
        }
        for i in 0..<max(0, Int(n)) {
            let name = withUnsafeBytes(of: list![i].name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let path = withUnsafeBytes(of: list![i].path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            listed.insert(path.isEmpty ? name : path)
            items.append(item(name: name, path: path, hidden: list![i].hidden != 0, enabled: true))
        }
        for entry in disabledLoginApps {
            guard let path = entry["path"] as? String, !listed.contains(path) else { continue }
            let name = entry["name"] as? String ?? (path as NSString).lastPathComponent
            items.append(item(name: name, path: path, hidden: entry["hidden"] as? Bool ?? false, enabled: false))
        }
    }

    private static func setOpenAtLogin(path: String, name: String, hidden: Bool, on: Bool) -> PrivilegedResponse {
        if on {
            guard FileManager.default.fileExists(atPath: path) else {
                return .failure(PrivilegedError(code: ENOENT, message: "\(path) no longer exists."))
            }
            let rc = si_login_item_add(path, hidden ? 1 : 0)
            guard rc == 0 else { return .failure(PrivilegedError(code: EIO, message: "Couldn't add \(name) to Open at Login.")) }
            disabledLoginApps.removeAll { $0["path"] as? String == path }
        } else {
            let rc = si_login_item_remove(path, name)
            guard rc == 0 || rc == -ENOENT else { return .failure(PrivilegedError(code: EIO, message: "Couldn't take \(name) off Open at Login.")) }
            var remembered = disabledLoginApps.filter { $0["path"] as? String != path }
            remembered.append(["path": path, "name": name, "hidden": hidden])
            disabledLoginApps = remembered
        }
        return .ok
    }

    private static func removeOpenAtLogin(path: String, name: String) -> PrivilegedResponse {
        let rc = si_login_item_remove(path, name)
        let wasRemembered = disabledLoginApps.contains { $0["path"] as? String == path && !path.isEmpty }
        disabledLoginApps.removeAll { $0["path"] as? String == path }
        guard rc == 0 || (rc == -ENOENT && wasRemembered) else {
            return .failure(PrivilegedError(code: rc == -ENOENT ? ENOENT : EIO, message: "Couldn't take \(name) off Open at Login."))
        }
        return .ok
    }

    /// The labels `launchctl print-disabled` lists as disabled.
    static func parseDisabled(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard state == "disabled" || state == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")))
        }
        return labels
    }

    /// Fills in which app extensions the user turned off, from `pluginkit -mA` ("-" before the
    /// identifier). Run as the user: the choice is per user.
    public static func applyAppExtensionElections(_ items: inout [StartupItem]) {
        guard items.contains(where: { if case .appExtension? = $0.toggle { return true } else { return false } }) else { return }
        var ignored = Set<String>()
        for line in ToolRunner.run("/usr/bin/pluginkit", ["-m", "-A"], timeout: 20).stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { continue }
            let id = trimmed.dropFirst().trimmingCharacters(in: .whitespaces).components(separatedBy: "(").first ?? ""
            ignored.insert(id)
        }
        for i in items.indices {
            guard case .appExtension(let id)? = items[i].toggle else { continue }
            let off = ignored.contains(id)
            items[i].isEnabled = !off
            if off { items[i].status = "Disabled" }
        }
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
            return realPath(s)
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
            var item = StartupItem(
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
                lastUsed: f["Last Use"].flatMap { dateFormatter.date(from: $0) })
            let plist = null(f["URL"]).flatMap { $0.hasSuffix(".plist") && $0.hasPrefix("/") ? $0 : nil }
            if typeValue & (0x4 | 0x8 | 0x10) != 0 {
                // Login items, agents and daemons are launchd jobs: daemons in the system domain, the
                // rest in the user's GUI domain. A property list's own Label beats the identifier.
                let label = plist.flatMap { NSDictionary(contentsOfFile: $0)?["Label"] as? String } ?? identifier
                let domain = typeValue & 0x10 != 0 ? "system" : "gui/\(r.uid >= 500 ? uid_t(r.uid) : Elevation.interactiveUid)"
                if let label {
                    item.toggle = .launchd(domain: domain, label: label)
                    if let plist, isManagedPath(plist) {
                        item.removal = .launchdPlist(domain: domain, label: label, plist: plist)
                    }
                }
            } else if category == .appExtensions, let id = identifier, path?.hasSuffix(".appex") == true {
                item.toggle = .appExtension(identifier: id)
            }
            items.append(item)
        }
        return items
    }

    /// Background Task Management writes home folders by user ID ("/Users/501/Library/…"); this
    /// puts the real home folder back.
    static func realPath(_ path: String) -> String {
        guard path.hasPrefix("/Users/") else { return path }
        let rest = path.dropFirst(7)
        let id = rest.prefix { $0 != "/" }
        guard let uid = uid_t(id), !FileManager.default.fileExists(atPath: "/Users/\(id)"),
              let home = UserNames.home(uid) else { return path }
        return home + rest.dropFirst(id.count)
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
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Jobs turned off here are comments with a marker.
            let disabled = line.hasPrefix(cronDisabledMarker)
            if disabled {
                line = String(line.dropFirst(cronDisabledMarker.count)).trimmingCharacters(in: .whitespaces)
            }
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
            // Jobs in /etc/crontab are edited there; the rest in their user's crontab.
            let owner = hasUserField ? nil : user
            items.append(StartupItem(
                id: "cron:\(source):\(index)", category: .cron, name: command, kind: "Cron job",
                path: executable.flatMap { $0.hasPrefix("/") ? $0 : nil }, status: disabled ? "Disabled" : "Scheduled", developer: nil,
                teamIdentifier: nil, identifier: nil, details: "\(schedule) — from \(source)", user: runAs,
                toggle: .cron(user: owner, line: line), removal: .cron(user: owner, line: line), isEnabled: !disabled))
        }
        return items
    }

    static func periodicScripts() -> [StartupItem] {
        var items: [StartupItem] = []
        for base in ["/etc/periodic", "/usr/local/etc/periodic"] {
            for dir in contents(of: base) {
                for script in contents(of: dir) {
                    let runs = FileManager.default.isExecutableFile(atPath: script)
                    items.append(StartupItem(
                        id: "periodic:\(script)", category: .periodic, name: (script as NSString).lastPathComponent,
                        kind: "\((dir as NSString).lastPathComponent.capitalized) script", path: script, status: runs ? "Scheduled" : "Disabled",
                        developer: nil, teamIdentifier: nil, identifier: nil,
                        toggle: .executable(path: script), removal: .trash(path: script), isEnabled: runs))
                }
            }
        }
        for name in ["daily", "weekly", "monthly"] {
            let path = "/etc/\(name).local"
            if FileManager.default.fileExists(atPath: path) {
                items.append(StartupItem(id: "periodic:\(path)", category: .periodic, name: "\(name).local", kind: "\(name.capitalized) script",
                                         path: path, status: "Scheduled", developer: nil, teamIdentifier: nil, identifier: nil,
                                         removal: .trash(path: path)))
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
                        developer: nil, teamIdentifier: nil, identifier: nil, details: "Set in \(path)", user: "root",
                        removal: .hook(plist: path, key: key)))
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
                    user: folder.hasPrefix("/Library") ? nil : UserNames.name(Elevation.interactiveUid),
                    // Removing an authorization plug-in the authorization database still names can
                    // stop anyone from logging in; that's for its uninstaller.
                    removal: category == .authorization || !isManagedPath(path) ? nil : .trash(path: path)))
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
                    user: scope == "_computerlevel" ? nil : scope,
                    removal: p["ProfileIdentifier"] is String ? .profile(identifier: id, user: scope == "_computerlevel" ? nil : scope) : nil))
            }
        }
        return items
    }

    // MARK: Changing items

    /// Prefix of a cron job turned off here, so it can be turned back on.
    static let cronDisabledMarker = "#procopticon-disabled: "

    /// Folders startup items may be removed from (or have their scripts changed in): launchd's,
    /// the plug-in folders, periodic's and the legacy startup items. Anything else is refused,
    /// even as root.
    static func isManagedPath(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else { return false }
        let parent = (standardized as NSString).deletingLastPathComponent
        let library = ["LaunchAgents", "LaunchDaemons", "Input Methods", "Screen Savers", "Spotlight", "QuickLook", "PreferencePanes",
                       "ScriptingAdditions", "Internet Plug-Ins", "Audio/Plug-Ins/HAL", "CoreMediaIO/Plug-Ins/DAL",
                       "DirectoryServices/PlugIns", "Contextual Menu Items", "StartupItems"]
        for folder in library {
            if parent == "/Library/" + folder { return true }
            // ~/Library/<folder> of any user (daemons and startup items only exist system-wide).
            let parts = parent.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 3, parts[0] == "Users", parts[2] == "Library",
               parts.dropFirst(3).joined(separator: "/") == folder, folder != "LaunchDaemons", folder != "StartupItems" {
                return true
            }
        }
        for base in ["/etc/periodic", "/private/etc/periodic", "/usr/local/etc/periodic"] where parent.hasPrefix(base + "/") {
            return (parent as NSString).deletingLastPathComponent == base
        }
        return ["/etc/daily.local", "/etc/weekly.local", "/etc/monthly.local",
                "/private/etc/daily.local", "/private/etc/weekly.local", "/private/etc/monthly.local"].contains(standardized)
    }

    /// Whether an action belongs to the user rather than root: their own launchd domain, crontab,
    /// app extensions, and files they can change. Those run in the app; the rest in the helper.
    public static func runsAsUser(_ action: StartupAction) -> Bool {
        let me = UserNames.name(getuid())
        func writable(_ path: String) -> Bool {
            FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
        }
        switch action {
        case .setEnabled(.launchd(let domain, _), _): return domain == "gui/\(getuid())"
        case .setEnabled(.appExtension, _), .setEnabled(.openAtLogin, _), .remove(.openAtLogin): return true
        case .setEnabled(.cron(let user, _), _), .remove(.cron(let user, _)): return user == me
        case .setEnabled(.executable(let path), _), .remove(.trash(let path)): return writable(path)
        case .remove(.launchdPlist(let domain, _, let plist)): return domain == "gui/\(getuid())" && writable(plist)
        case .remove(.hook), .remove(.profile): return false
        }
    }

    /// Carries out an action with this process's privileges.
    public static func perform(_ action: StartupAction) -> PrivilegedResponse {
        func fail(_ message: String, _ code: Int32 = EIO) -> PrivilegedResponse {
            .failure(PrivilegedError(code: code, message: message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        func run(_ tool: String, _ args: [String]) -> PrivilegedResponse {
            let out = ToolRunner.run(tool, args, timeout: 30)
            if out.status == 0 { return .ok }
            let message = out.combined.isEmpty ? "\((tool as NSString).lastPathComponent) exited with status \(out.status)." : out.combined
            return fail(message, out.combined.localizedCaseInsensitiveContains("not permitted") ? EPERM : EIO)
        }
        switch action {
        case .setEnabled(.launchd(let domain, let label), let on):
            return run("/bin/launchctl", [on ? "enable" : "disable", "\(domain)/\(label)"])
        case .setEnabled(.appExtension(let id), let on):
            return run("/usr/bin/pluginkit", ["-e", on ? "use" : "ignore", "-i", id])
        case .setEnabled(.openAtLogin(let path, let name, let hidden), let on):
            return setOpenAtLogin(path: path, name: name, hidden: hidden, on: on)
        case .remove(.openAtLogin(let path, let name)):
            return removeOpenAtLogin(path: path, name: name)
        case .setEnabled(.cron(let user, let line), let on):
            return editCrontab(user: user) { editCron($0, line: line, operation: on ? .enable : .disable) }
        case .setEnabled(.executable(let path), let on):
            guard isManagedPath(path) else { return fail("\(path) isn't a periodic script.", EPERM) }
            do {
                let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
                let newMode = on ? mode | 0o111 : mode & ~0o111
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: newMode)], ofItemAtPath: path)
                return .ok
            } catch {
                return fail(error.localizedDescription, (error as NSError).code == NSFileWriteNoPermissionError ? EPERM : EIO)
            }
        case .remove(.launchdPlist(let domain, let label, let plist)):
            guard isManagedPath(plist), plist.hasSuffix(".plist") else { return fail("\(plist) isn't a launchd property list.", EPERM) }
            // Not loaded is fine; it's going anyway.
            _ = ToolRunner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 30)
            return moveToTrash(plist)
        case .remove(.cron(let user, let line)):
            return editCrontab(user: user) { editCron($0, line: line, operation: .remove) }
        case .remove(.trash(let path)):
            guard isManagedPath(path) else { return fail("\(path) isn't in a startup or plug-in folder.", EPERM) }
            return moveToTrash(path)
        case .remove(.hook(let plist, let key)):
            guard ["/var/root/Library/Preferences/com.apple.loginwindow.plist", "/Library/Preferences/com.apple.loginwindow.plist"].contains(plist),
                  key == "LoginHook" || key == "LogoutHook" else { return fail("Not a login hook.", EINVAL) }
            return run("/usr/bin/defaults", ["delete", (plist as NSString).deletingPathExtension, key])
        case .remove(.profile(let identifier, let user)):
            return run("/usr/bin/profiles", ["remove", "-identifier", identifier, "-forced"] + (user.map { ["-user", $0] } ?? []))
        }
    }

    enum CronOperation {
        case enable, disable, remove
    }

    /// The crontab with the job's line turned off (commented with the marker), back on, or gone;
    /// nil when the line isn't there.
    static func editCron(_ text: String, line: String, operation: CronOperation) -> String? {
        let target = line.trimmingCharacters(in: .whitespaces)
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { candidate in
            var c = candidate.trimmingCharacters(in: .whitespaces)
            if c.hasPrefix(cronDisabledMarker) { c = String(c.dropFirst(cronDisabledMarker.count)).trimmingCharacters(in: .whitespaces) }
            return c == target
        }) else { return nil }
        switch operation {
        case .enable: lines[index] = target
        case .disable: lines[index] = cronDisabledMarker + target
        case .remove: lines.remove(at: index)
        }
        return lines.joined(separator: "\n")
    }

    /// Reads a crontab, edits it and installs the result: /etc/crontab directly (user nil), a user's
    /// with crontab(1).
    private static func editCrontab(user: String?, _ edit: (String) -> String?) -> PrivilegedResponse {
        if user == nil {
            let path = "/etc/crontab"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .failure(PrivilegedError(code: ENOENT, message: "Can't read /etc/crontab."))
            }
            guard let edited = edit(text) else {
                return .failure(PrivilegedError(code: ENOENT, message: "The job is no longer in /etc/crontab."))
            }
            do {
                try edited.write(toFile: path, atomically: true, encoding: .utf8)
                return .ok
            } catch {
                return .failure(PrivilegedError(code: EPERM, message: error.localizedDescription))
            }
        }
        let other = geteuid() == 0 && user != UserNames.name(getuid())
        let userArgs = other ? ["-u", user!] : []
        let current = ToolRunner.run("/usr/bin/crontab", userArgs + ["-l"], timeout: 10)
        guard current.status == 0 else {
            return .failure(PrivilegedError(code: ENOENT, message: current.combined.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard var edited = edit(current.stdout) else {
            return .failure(PrivilegedError(code: ENOENT, message: "The job is no longer in the crontab."))
        }
        if !edited.hasSuffix("\n") { edited += "\n" }
        let file = NSTemporaryDirectory() + "procopticon-crontab-\(UUID().uuidString)"
        defer { unlink(file) }
        do {
            try edited.write(toFile: file, atomically: true, encoding: .utf8)
        } catch {
            return .failure(PrivilegedError(code: EIO, message: error.localizedDescription))
        }
        let install = ToolRunner.run("/usr/bin/crontab", userArgs + [file], timeout: 10)
        return install.status == 0 ? .ok
            : .failure(PrivilegedError(code: EIO, message: install.combined.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Moves a file to the Trash: the usual way for the user's own, or, as root, into the
    /// interactive user's Trash folder, so it can still be put back.
    static func moveToTrash(_ path: String) -> PrivilegedResponse {
        let url = URL(fileURLWithPath: path)
        if geteuid() != 0 {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return .ok
            } catch {
                let code: Int32 = (error as NSError).code == NSFileWriteNoPermissionError ? EPERM : EIO
                return .failure(PrivilegedError(code: code, message: error.localizedDescription))
            }
        }
        guard let home = UserNames.home(Elevation.interactiveUid) else {
            return .failure(PrivilegedError(code: ENOENT, message: "Can't find your Trash."))
        }
        let trash = URL(fileURLWithPath: home).appendingPathComponent(".Trash")
        let name = url.lastPathComponent
        var destination = trash.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
            destination = trash.appendingPathComponent("\((name as NSString).deletingPathExtension) \(stamp)" +
                (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"))
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return .ok
        } catch {
            return .failure(PrivilegedError(code: EIO, message: error.localizedDescription))
        }
    }

    private static func contents(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().map { folder + "/" + $0 }
    }
}
