import AppKit
import Combine
import InformerCore
import SwiftUI

/// Persistent user preferences.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var refreshInterval: Double { didSet { save("refreshInterval", refreshInterval); apply() } }
    @Published var highlightDuration: Double { didSet { save("highlightDuration", highlightDuration); apply() } }
    @Published var cpuScaleToSystem: Bool { didSet { save("cpuScaleToSystem", cpuScaleToSystem); apply() } }
    @Published var treeView: Bool { didSet { save("treeView", treeView); apply() } }
    @Published var confirmActions: Bool { didSet { save("confirmActions", confirmActions) } }
    @Published var showMenuBarExtra: Bool { didSet { save("showMenuBarExtra", showMenuBarExtra) } }
    @Published var elevateAtLaunch: Bool { didSet { save("elevateAtLaunch", elevateAtLaunch) } }
    @Published var hideOtherUsers: Bool { didSet { save("hideOtherUsers", hideOtherUsers); apply() } }
    @Published var hideSystemProcesses: Bool { didSet { save("hideSystemProcesses", hideSystemProcesses); apply() } }
    @Published var hideAppleProcesses: Bool { didSet { save("hideAppleProcesses", hideAppleProcesses); apply() } }
    @Published var hideZombies: Bool { didSet { save("hideZombies", hideZombies); apply() } }
    @Published var onlyApplications: Bool { didSet { save("onlyApplications", onlyApplications); apply() } }
    @Published var resolveAddresses: Bool { didSet { save("resolveAddresses", resolveAddresses); apply() } }
    @Published var alwaysOnTop: Bool { didSet { save("alwaysOnTop", alwaysOnTop); applyWindowLevel() } }
    @Published var showStatusBar: Bool { didSet { save("showStatusBar", showStatusBar) } }
    @Published var menuBarGraph: MenuBarGraphKind { didSet { save("menuBarGraph", menuBarGraph.rawValue) } }
    @Published var searchEngineURL: String { didSet { save("searchEngineURL", searchEngineURL) } }
    @Published var searchUsesRegex: Bool { didSet { save("searchUsesRegex", searchUsesRegex); apply() } }
    @Published var processListMonospaced: Bool { didSet { save("processListMonospaced", processListMonospaced) } }
    @Published var processListFontSize: Double { didSet { save("processListFontSize", processListFontSize) } }
    @Published var savedFilters: [SavedFilter] {
        didSet {
            if let data = try? JSONEncoder().encode(savedFilters) {
                defaults.set(data, forKey: "savedFilters")
            }
        }
    }
    @Published var highlights: [HighlightRule: HighlightSetting] { didSet { saveHighlights() } }

    enum MenuBarGraphKind: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case memory = "Memory"
        case cpuAndMemory = "CPU + Memory"
        case network = "Network"
        case disk = "Disk"
        var id: String { rawValue }
    }

    private init() {
        let defaults = UserDefaults.standard
        let d = { (k: String, v: Double) -> Double in defaults.object(forKey: k) as? Double ?? v }
        let b = { (k: String, v: Bool) -> Bool in defaults.object(forKey: k) as? Bool ?? v }
        refreshInterval = d("refreshInterval", 1.0)
        highlightDuration = d("highlightDuration", 2.0)
        cpuScaleToSystem = b("cpuScaleToSystem", true)
        treeView = b("treeView", true)
        confirmActions = b("confirmActions", true)
        showMenuBarExtra = b("showMenuBarExtra", true)
        elevateAtLaunch = b("elevateAtLaunch", false)
        hideOtherUsers = b("hideOtherUsers", false)
        hideSystemProcesses = b("hideSystemProcesses", false)
        hideAppleProcesses = b("hideAppleProcesses", false)
        hideZombies = b("hideZombies", false)
        onlyApplications = b("onlyApplications", false)
        resolveAddresses = b("resolveAddresses", true)
        alwaysOnTop = b("alwaysOnTop", false)
        showStatusBar = b("showStatusBar", true)
        menuBarGraph = MenuBarGraphKind(rawValue: defaults.string(forKey: "menuBarGraph") ?? "") ?? .cpu
        searchEngineURL = defaults.string(forKey: "searchEngineURL") ?? "https://duckduckgo.com/?q=%s"
        searchUsesRegex = b("searchUsesRegex", false)
        processListMonospaced = b("processListMonospaced", false)
        processListFontSize = d("processListFontSize", Double(NSFont.systemFontSize(for: .small) + 1))
        if let data = defaults.data(forKey: "savedFilters"), let list = try? JSONDecoder().decode([SavedFilter].self, from: data) {
            savedFilters = list
        } else {
            savedFilters = SavedFilter.defaults
        }
        var h: [HighlightRule: HighlightSetting] = [:]
        let saved = defaults.dictionary(forKey: "highlights") as? [String: [String: Any]] ?? [:]
        for rule in HighlightRule.allCases {
            var setting = HighlightSetting(enabled: rule.defaultEnabled, color: rule.defaultColor)
            if let s = saved[rule.rawValue] {
                setting.enabled = s["enabled"] as? Bool ?? setting.enabled
                if let hex = s["color"] as? String, let c = NSColor(hex: hex) {
                    setting.color = c
                }
            }
            h[rule] = setting
        }
        highlights = h
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    private func saveHighlights() {
        var out: [String: [String: Any]] = [:]
        for (rule, s) in highlights {
            out[rule.rawValue] = ["enabled": s.enabled, "color": s.color.hexString]
        }
        defaults.set(out, forKey: "highlights")
        ProcessStore.shared.objectWillChange.send()
        NotificationCenter.default.post(name: .highlightsChanged, object: nil)
    }

    func resetHighlights() {
        var h: [HighlightRule: HighlightSetting] = [:]
        for rule in HighlightRule.allCases {
            h[rule] = HighlightSetting(enabled: rule.defaultEnabled, color: rule.defaultColor)
        }
        highlights = h
    }

    /// Push settings into the live stores.
    func apply() {
        let store = ProcessStore.shared
        store.interval = refreshInterval
        store.highlightDuration = highlightDuration
        store.scaleCPUToSystem = cpuScaleToSystem
        store.treeMode = treeView
        var f = store.filter
        f.hideOtherUsers = hideOtherUsers
        f.hideSystemProcesses = hideSystemProcesses
        f.hideAppleProcesses = hideAppleProcesses
        f.hideZombies = hideZombies
        f.regex = searchUsesRegex
        f.onlyApplications = onlyApplications
        store.filter = f
        NetworkStore.shared.highlightDuration = highlightDuration
        NetworkStore.shared.resolveAddresses = resolveAddresses
    }

    func applyWindowLevel() {
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true || window.title == "Process Informer" {
            window.level = alwaysOnTop ? .floating : .normal
        }
    }
}

extension Notification.Name {
    static let highlightsChanged = Notification.Name("ProcessInformer.HighlightsChanged")
}

struct HighlightSetting {
    var enabled: Bool
    var color: NSColor
}

/// Row highlighting categories, highest priority first.
enum HighlightRule: String, CaseIterable, Identifiable {
    case removed
    case new
    case suspended
    case zombie
    case debugged
    case translated
    case elevated
    case unsigned
    case sandboxed
    case application
    case ownProcesses
    case systemProcesses
    case daemons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .removed: return "Terminated processes"
        case .new: return "New processes"
        case .suspended: return "Stopped (suspended) processes"
        case .zombie: return "Zombie processes"
        case .debugged: return "Processes being traced/debugged"
        case .translated: return "Rosetta (x86_64) processes"
        case .elevated: return "Elevated processes (setuid / sudo)"
        case .unsigned: return "Unsigned or invalid signature"
        case .sandboxed: return "Sandboxed processes"
        case .application: return "Applications"
        case .ownProcesses: return "Own processes"
        case .systemProcesses: return "Root processes"
        case .daemons: return "System daemons (service accounts)"
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .application, .sandboxed: return false
        default: return true
        }
    }

    var defaultColor: NSColor {
        switch self {
        case .removed: return NSColor(hex: "#FF3C3C")!
        case .new: return NSColor(hex: "#33D17A")!
        case .suspended: return NSColor(hex: "#8E8E93")!
        case .zombie: return NSColor(hex: "#5E5C64")!
        case .debugged: return NSColor(hex: "#B07CFF")!
        case .translated: return NSColor(hex: "#FF9F0A")!
        case .elevated: return NSColor(hex: "#FFB340")!
        case .unsigned: return NSColor(hex: "#FF6FB5")!
        case .sandboxed: return NSColor(hex: "#40C8E0")!
        case .application: return NSColor(hex: "#64D2FF")!
        case .ownProcesses: return NSColor(hex: "#FFE066")!
        case .systemProcesses: return NSColor(hex: "#5AA9FF")!
        case .daemons: return NSColor(hex: "#C9A7FF")!
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

enum Highlighter {
    /// Background for a process row, or nil.
    static func style(for item: ProcessItem, store: ProcessStore = .shared) -> RowStyle? {
        let settings = AppSettings.shared.highlights
        func use(_ rule: HighlightRule) -> RowStyle? {
            guard let s = settings[rule], s.enabled else { return nil }
            let alpha: CGFloat = (rule == .removed || rule == .new) ? 0.55 : 0.28
            return RowStyle(background: s.color.withAlphaComponent(alpha))
        }
        let r = item.record
        if item.isRemoved, let s = use(.removed) { return s }
        if store.isNew(item), let s = use(.new) { return s }
        if r.isStopped, let s = use(.suspended) { return s }
        if r.isZombie, let s = use(.zombie) { return s }
        if r.isTraced, let s = use(.debugged) { return s }
        if r.isTranslated, let s = use(.translated) { return s }
        if r.isElevated, let s = use(.elevated) { return s }
        if settings[.unsigned]?.enabled == true, let flags = r.csFlags, r.pid != 0,
           flags & CodeSigningFlags.valid == 0 || flags & CodeSigningFlags.signed == 0 {
            if let s = use(.unsigned) { return s }
        }
        if r.sandboxed == true, let s = use(.sandboxed) { return s }
        if settings[.application]?.enabled == true, item.bundleInfo?.isApplication == true, let s = use(.application) { return s }
        let me = Elevation.interactiveUid
        if r.uid == me, let s = use(.ownProcesses) { return s }
        if r.uid == 0, let s = use(.systemProcesses) { return s }
        if r.uid < 500, let s = use(.daemons) { return s }
        return nil
    }
}

extension AppSettings {
    /// Matcher for a filter field, honoring the regular-expression preference.
    func matcher(_ text: String) -> SearchMatcher {
        SearchMatcher(text, regex: searchUsesRegex)
    }
}

extension AppSettings {
    /// True when any of the persistent process filters is active.
    var hasProcessFilters: Bool {
        onlyApplications || hideOtherUsers || hideSystemProcesses || hideAppleProcesses || hideZombies
    }

    func resetProcessFilters() {
        onlyApplications = false
        hideOtherUsers = false
        hideSystemProcesses = false
        hideAppleProcesses = false
        hideZombies = false
    }
}

/// PIDs of GUI applications: LaunchServices "regular" apps plus owners of normal-level windows
/// (the latter also covers sessions where LaunchServices sees fewer apps, e.g. when running as root).
enum ApplicationPids {
    static func current() -> Set<Int32> {
        var pids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? Int32 {
                pids.insert(pid)
            }
        }
        return pids
    }
}

extension AppSettings {
    /// Font for the process list (fixed-width when enabled).
    var processListFont: NSFont {
        let size = CGFloat(processListFontSize)
        return processListMonospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }
}
