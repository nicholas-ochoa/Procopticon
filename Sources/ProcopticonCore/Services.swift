import Darwin
import Foundation

public enum ServiceDomain: Hashable, Sendable {
    case system
    case gui(uid_t)

    public var target: String {
        switch self {
        case .system: return "system"
        case .gui(let uid): return "gui/\(uid)"
        }
    }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .gui(let uid): return "User (\(UserNames.name(uid)))"
        }
    }

    public var requiresRoot: Bool {
        switch self {
        case .system: return true
        case .gui(let uid): return uid != getuid()
        }
    }
}

public enum ServiceKind: String, Sendable {
    case daemon = "Launch daemon"
    case agent = "Launch agent"
    case loginItem = "Login item"
    case xpc = "XPC / on-demand"
}

public struct ServiceItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(domain.target)/\(label)" }
    public var label: String
    public var domain: ServiceDomain
    public var pid: Int32?
    public var lastExitStatus: String
    public var loaded: Bool
    public var disabled: Bool?
    public var plistPath: String?
    public var program: String?
    public var arguments: [String]
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var userName: String?
    public var kind: ServiceKind
    public var machServices: [String]
    public var startInterval: Int?

    public var isApple: Bool { label.hasPrefix("com.apple.") }
    public var isRunning: Bool { (pid ?? 0) > 0 }

    public var statusDescription: String {
        if isRunning { return "Running" }
        if !loaded { return "Not loaded" }
        if disabled == true { return "Disabled" }
        return "Stopped"
    }

    public var startTypeDescription: String {
        var parts: [String] = []
        if runAtLoad { parts.append("At load") }
        if keepAlive { parts.append("Keep alive") }
        if let startInterval { parts.append("Every \(startInterval)s") }
        if !machServices.isEmpty, parts.isEmpty { parts.append("On demand") }
        return parts.joined(separator: ", ")
    }

    public var executable: String? {
        program ?? arguments.first
    }

    public var fullTarget: String { "\(domain.target)/\(label)" }
}

public enum ServiceProvider {
    struct PlistInfo {
        var path: String
        var program: String?
        var arguments: [String]
        var runAtLoad: Bool
        var keepAlive: Bool
        var disabled: Bool
        var userName: String?
        var machServices: [String]
        var startInterval: Int?
        var kind: ServiceKind
    }

    public static func plistDirectories(uid: uid_t) -> [(String, ServiceKind, Bool)] {
        let home = UserNames.home(uid) ?? NSHomeDirectory()
        return [
            ("/System/Library/LaunchDaemons", .daemon, true),
            ("/Library/LaunchDaemons", .daemon, true),
            ("/System/Library/LaunchAgents", .agent, false),
            ("/Library/LaunchAgents", .agent, false),
            ("\(home)/Library/LaunchAgents", .agent, false),
        ]
    }

    static func readPlists(uid: uid_t) -> (system: [String: PlistInfo], user: [String: PlistInfo]) {
        var system: [String: PlistInfo] = [:]
        var user: [String: PlistInfo] = [:]
        for (dir, kind, isSystem) in plistDirectories(uid: uid) {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let data = FileManager.default.contents(atPath: path),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = dict["Label"] as? String else { continue }
                let keepAlive: Bool
                if let b = dict["KeepAlive"] as? Bool {
                    keepAlive = b
                } else {
                    keepAlive = dict["KeepAlive"] is [String: Any]
                }
                let info = PlistInfo(
                    path: path, program: dict["Program"] as? String,
                    arguments: dict["ProgramArguments"] as? [String] ?? [],
                    runAtLoad: dict["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                    disabled: dict["Disabled"] as? Bool ?? false, userName: dict["UserName"] as? String,
                    machServices: (dict["MachServices"] as? [String: Any]).map { Array($0.keys).sorted() } ?? [],
                    startInterval: dict["StartInterval"] as? Int, kind: kind)
                if isSystem {
                    system[label] = info
                } else {
                    user[label] = info
                }
            }
        }
        return (system, user)
    }

    /// Parses `launchctl print <domain>` output: services list and disabled overrides.
    static func parsePrint(_ text: String) -> (services: [(label: String, pid: Int32, status: String)], disabled: [String: Bool]) {
        var services: [(String, Int32, String)] = []
        var disabled: [String: Bool] = [:]
        enum Section { case none, services, disabled }
        var section = Section.none
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if rawLine.hasPrefix("\tservices = {") {
                section = .services
                continue
            }
            if rawLine.hasPrefix("\tdisabled services = {") {
                section = .disabled
                continue
            }
            if line == "}" {
                section = .none
                continue
            }
            switch section {
            case .services:
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                    .flatMap { $0.split(separator: "\t", omittingEmptySubsequences: true) }
                guard parts.count >= 3 else { continue }
                let pid = Int32(parts[0]) ?? 0
                let status = String(parts[1])
                let label = parts[2...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
                services.append((label, pid, status))
            case .disabled:
                // "label" => disabled
                guard let arrow = line.range(of: " => ") else { continue }
                let label = line[..<arrow.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                disabled[label] = value == "disabled"
            case .none:
                break
            }
        }
        return (services, disabled)
    }

    /// Lists services in the system domain and the interactive user's GUI domain.
    public static func list(uid: uid_t = Elevation.interactiveUid) -> [ServiceItem] {
        let plists = readPlists(uid: uid)
        var items: [ServiceItem] = []
        let domains: [(ServiceDomain, [String: PlistInfo])] = [(.system, plists.system), (.gui(uid), plists.user)]
        for (domain, plistMap) in domains {
            let output = ToolRunner.run("/bin/launchctl", ["print", domain.target], timeout: 15).stdout
            let parsed = parsePrint(output)
            var seen = Set<String>()
            for entry in parsed.services {
                seen.insert(entry.label)
                let p = plistMap[entry.label]
                items.append(ServiceItem(
                    label: entry.label, domain: domain, pid: entry.pid > 0 ? entry.pid : nil,
                    lastExitStatus: entry.status, loaded: true,
                    disabled: parsed.disabled[entry.label] ?? p?.disabled,
                    plistPath: p?.path, program: p?.program, arguments: p?.arguments ?? [],
                    runAtLoad: p?.runAtLoad ?? false, keepAlive: p?.keepAlive ?? false, userName: p?.userName,
                    kind: p?.kind ?? (entry.label.hasPrefix("application.") ? .loginItem : .xpc),
                    machServices: p?.machServices ?? [], startInterval: p?.startInterval))
            }
            // Installed but not loaded jobs.
            for (label, p) in plistMap where !seen.contains(label) {
                items.append(ServiceItem(
                    label: label, domain: domain, pid: nil, lastExitStatus: "-", loaded: false,
                    disabled: parsed.disabled[label] ?? p.disabled, plistPath: p.path, program: p.program,
                    arguments: p.arguments, runAtLoad: p.runAtLoad, keepAlive: p.keepAlive, userName: p.userName,
                    kind: p.kind, machServices: p.machServices, startInterval: p.startInterval))
            }
        }
        return items
    }

    public enum Action: String, CaseIterable, Sendable {
        case start = "Start"
        case stop = "Stop"
        case restart = "Restart"
        case load = "Load"
        case unload = "Unload"
        case enable = "Enable"
        case disable = "Disable"
    }

    public static func launchctlArguments(for action: Action, service: ServiceItem) -> [String]? {
        switch action {
        case .start: return ["kickstart", service.fullTarget]
        case .restart: return ["kickstart", "-k", service.fullTarget]
        case .stop: return ["kill", "SIGTERM", service.fullTarget]
        case .load:
            guard let plist = service.plistPath else { return nil }
            return ["bootstrap", service.domain.target, plist]
        case .unload: return ["bootout", service.fullTarget]
        case .enable: return ["enable", service.fullTarget]
        case .disable: return ["disable", service.fullTarget]
        }
    }

    /// Performs an action, elevating when the domain requires it.
    public static func perform(_ action: Action, on service: ServiceItem) async -> Result<String, PrivilegedError> {
        guard let args = launchctlArguments(for: action, service: service) else {
            return .failure(PrivilegedError(code: EINVAL, message: "\(action.rawValue) is not available for \(service.label)."))
        }
        let response = await Elevation.shared.performElevated(
            .runTool(tool: "/bin/launchctl", arguments: args), requiresRoot: service.domain.requiresRoot)
        switch response {
        case .tool(let out):
            if out.status != 0 {
                let msg = out.combined.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(PrivilegedError(code: out.status, message: msg.isEmpty ? "launchctl exited with status \(out.status)" : msg))
            }
            return .success(out.combined)
        case .failure(let e):
            return .failure(e)
        default:
            return .failure(PrivilegedError(code: EIO, message: "Unexpected response"))
        }
    }

    /// `launchctl print <domain>/<label>` details.
    public static func details(of service: ServiceItem) async -> String {
        let response = await Elevation.shared.performElevated(
            .runTool(tool: "/bin/launchctl", arguments: ["print", service.fullTarget]), prompt: false)
        if case .tool(let out) = response {
            return out.combined
        }
        return response.error?.message ?? ""
    }
}
