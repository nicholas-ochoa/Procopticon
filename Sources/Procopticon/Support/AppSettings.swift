import AppKit
import Combine
import ProcopticonCore
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
    /// The kinds of action whose confirmation was dismissed with "Don't ask again" (see `Alerts.confirm`).
    @Published var suppressedConfirmations: Set<String> {
        didSet { save("suppressedConfirmations", suppressedConfirmations.sorted()) }
    }
    @Published var showMenuBarExtra: Bool { didSet { save("showMenuBarExtra", showMenuBarExtra) } }
    @Published var elevateAtLaunch: Bool { didSet { save("elevateAtLaunch", elevateAtLaunch) } }
    @Published var hideOtherUsers: Bool { didSet { save("hideOtherUsers", hideOtherUsers); apply() } }
    @Published var hideSystemProcesses: Bool { didSet { save("hideSystemProcesses", hideSystemProcesses); apply() } }
    @Published var hideAppleProcesses: Bool { didSet { save("hideAppleProcesses", hideAppleProcesses); apply() } }
    @Published var hideZombies: Bool { didSet { save("hideZombies", hideZombies); apply() } }
    @Published var onlyApplications: Bool { didSet { save("onlyApplications", onlyApplications); apply() } }
    @Published var onlyNotResponding: Bool { didSet { save("onlyNotResponding", onlyNotResponding); apply() } }
    @Published var resolveAddresses: Bool { didSet { save("resolveAddresses", resolveAddresses); apply() } }
    @Published var alwaysOnTop: Bool { didSet { save("alwaysOnTop", alwaysOnTop); applyWindowLevel() } }
    @Published var showStatusBar: Bool { didSet { save("showStatusBar", showStatusBar) } }
    @Published var menuBarGraph: MenuBarGraphKind { didSet { save("menuBarGraph", menuBarGraph.rawValue) } }
    @Published var searchEngineURL: String { didSet { save("searchEngineURL", searchEngineURL) } }
    /// Search text is a regular expression, in every search field.
    @Published var searchUsesRegex: Bool {
        didSet {
            save("searchUsesRegex", searchUsesRegex)
            if searchUsesRegex, searchUsesJavaScript { searchUsesJavaScript = false }
            apply()
        }
    }
    /// The process search is a JavaScript expression (see `ProcessExpressions`); other searches
    /// don't have this mode. Exclusive with `searchUsesRegex`.
    @Published var searchUsesJavaScript: Bool {
        didSet {
            save("searchUsesJavaScript", searchUsesJavaScript)
            if searchUsesJavaScript, searchUsesRegex { searchUsesRegex = false }
            apply()
        }
    }
    @Published var processListMonospaced: Bool { didSet { save("processListMonospaced", processListMonospaced) } }
    @Published var processListFontSize: Double { didSet { save("processListFontSize", processListFontSize) } }
    @Published var appearance: AppearanceMode { didSet { save("appearance", appearance.rawValue); applyAppearance() } }
    @Published var accent: AccentChoice { didSet { save("accent", accent.rawValue); applyAccentColor() } }
    /// The color for `AccentChoice.custom`, kept while another choice is selected.
    @Published var accentCustom: NSColor { didSet { save("accentCustom", accentCustom.hexString); applyAccentColor() } }
    @Published var savedFilters: [SavedFilter] {
        didSet {
            if let data = try? JSONEncoder().encode(savedFilters) {
                defaults.set(data, forKey: "savedFilters")
            }
        }
    }
    @Published var highlights: [HighlightRule: HighlightSetting] { didSet { saveHighlights() } }
    @Published var customHighlights: [CustomHighlight] {
        didSet {
            if let data = try? JSONEncoder().encode(customHighlights) {
                defaults.set(data, forKey: "customHighlights")
            }
            applyCustomHighlights()
            NotificationCenter.default.post(name: .highlightsChanged, object: nil)
        }
    }
    @Published var alertRules: [AlertRule] {
        didSet {
            if let data = try? JSONEncoder().encode(alertRules) {
                defaults.set(data, forKey: "alertRules")
            }
        }
    }
    @Published var alertNotifications: Bool { didSet { save("alertNotifications", alertNotifications) } }
    @Published var alertSound: Bool { didSet { save("alertSound", alertSound) } }

    /// Light or dark for every window, or System to follow macOS.
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
        var id: String { rawValue }

        /// nil follows the system appearance.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    /// The app's accent color, from System Settings' palette, or any color.
    enum AccentChoice: String, CaseIterable, Identifiable {
        case system, blue, purple, pink, red, orange, yellow, green, graphite, custom
        var id: String { rawValue }

        var title: String {
            self == .system ? "System" : rawValue.capitalized
        }

        /// nil follows the system's accent color.
        func color(custom: NSColor) -> NSColor? {
            switch self {
            case .system: nil
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .pink: .systemPink
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .graphite: .systemGray
            case .custom: custom
            }
        }
    }

    func applyAccentColor() {
        AccentColor.apply(accent.color(custom: accentCustom))
    }

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
        suppressedConfirmations = Set(defaults.stringArray(forKey: "suppressedConfirmations") ?? [])
        showMenuBarExtra = b("showMenuBarExtra", true)
        elevateAtLaunch = b("elevateAtLaunch", false)
        hideOtherUsers = b("hideOtherUsers", false)
        hideSystemProcesses = b("hideSystemProcesses", false)
        hideAppleProcesses = b("hideAppleProcesses", false)
        hideZombies = b("hideZombies", false)
        onlyApplications = b("onlyApplications", false)
        onlyNotResponding = b("onlyNotResponding", false)
        resolveAddresses = b("resolveAddresses", true)
        alwaysOnTop = b("alwaysOnTop", false)
        showStatusBar = b("showStatusBar", true)
        menuBarGraph = MenuBarGraphKind(rawValue: defaults.string(forKey: "menuBarGraph") ?? "") ?? .cpu
        searchEngineURL = defaults.string(forKey: "searchEngineURL") ?? "https://duckduckgo.com/?q=%s"
        let regex = b("searchUsesRegex", false)
        searchUsesRegex = regex
        searchUsesJavaScript = b("searchUsesJavaScript", false) && !regex
        processListMonospaced = b("processListMonospaced", false)
        processListFontSize = d("processListFontSize", Double(NSFont.systemFontSize(for: .small) + 1))
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        accent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .system
        accentCustom = defaults.string(forKey: "accentCustom").flatMap(NSColor.init(hex:)) ?? .systemTeal
        savedFilters = Self.savedList("savedFilters", in: defaults, otherwise: SavedFilter.defaults).map { $0.migrated() }
        alertRules = Self.savedList("alertRules", in: defaults, otherwise: AlertRule.examples)
        alertNotifications = b("alertNotifications", true)
        alertSound = b("alertSound", false)
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
        customHighlights = Self.savedList("customHighlights", in: defaults, otherwise: CustomHighlight.examples)
    }

    /// The list saved under `key`, or `fallback` when nothing was saved. When the list as a whole
    /// can't be read (one rule written by a newer version, say), every entry that can be is kept,
    /// rather than all of them being replaced by the examples. What couldn't be read is copied to
    /// `<key>.unreadable` first, since the next edit saves the list without it.
    static func savedList<T: Decodable>(_ key: String, in defaults: UserDefaults, otherwise fallback: [T]) -> [T] {
        guard let data = defaults.data(forKey: key) else { return fallback }
        if let list = try? JSONDecoder().decode([T].self, from: data) { return list }
        defaults.set(data, forKey: key + ".unreadable")
        return LenientList.decode(T.self, from: data) ?? fallback
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

    /// Turns every built-in highlight rule on or off, keeping their colors.
    func setAllHighlights(enabled: Bool) {
        var h = highlights
        for rule in HighlightRule.allCases {
            h[rule, default: HighlightSetting(enabled: enabled, color: rule.defaultColor)].enabled = enabled
        }
        highlights = h
    }

    /// Turns every custom highlight rule on or off.
    func setAllCustomHighlights(enabled: Bool) {
        var custom = customHighlights
        for i in custom.indices {
            custom[i].enabled = enabled
        }
        customHighlights = custom
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
        f.mode = processSearchMode
        f.onlyApplications = onlyApplications
        f.onlyNotResponding = onlyNotResponding
        store.filter = f
        applyCustomHighlights()
        NetworkStore.shared.highlightDuration = highlightDuration
        NetworkStore.shared.resolveAddresses = resolveAddresses
    }

    /// How the process search matches.
    var processSearchMode: SearchMode {
        get { searchUsesJavaScript ? .javascript : searchUsesRegex ? .regex : .text }
        set {
            searchUsesJavaScript = newValue == .javascript
            searchUsesRegex = newValue == .regex
        }
    }

    /// Hands the enabled custom highlight rules to the store, which evaluates them for each process.
    private func applyCustomHighlights() {
        ProcessStore.shared.highlightFilters = customHighlights
            .filter(\.enabled)
            .map { HighlightFilter(id: $0.id, text: $0.text, mode: $0.mode) }
    }

    func applyWindowLevel() {
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true || window.title == "Procopticon" {
            window.level = alwaysOnTop ? .floating : .normal
        }
    }
}

extension Notification.Name {
    static let highlightsChanged = Notification.Name("Procopticon.HighlightsChanged")
}

struct HighlightSetting {
    var enabled: Bool
    var color: NSColor
}

/// A highlight rule of your own: processes for which `expression` is true get `color`.
struct CustomHighlight: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var name = ""
    /// What the rule matches, as `mode` says: text, a regular expression or a JavaScript expression.
    var text = ""
    var mode = SearchMode.text
    var colorHex = "#FF9F0A"

    var color: NSColor {
        get { NSColor(hex: colorHex) ?? .systemOrange }
        set { colorHex = newValue.hexString }
    }

    var title: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? mode.describe(text.trimmingCharacters(in: .whitespacesAndNewlines)) : n
    }

    static let examples: [CustomHighlight] = [
        CustomHighlight(enabled: false, name: "Using over 2 GB of memory", text: "memory > 2 * GB", mode: .javascript, colorHex: "#FF6482"),
        CustomHighlight(enabled: false, name: "Busy for an hour or more", text: "cpu > 50 && age > 3600", mode: .javascript, colorHex: "#FF9F0A"),
    ]

    init(enabled: Bool = true, name: String = "", text: String = "", mode: SearchMode = .text, colorHex: String = "#FF9F0A") {
        self.enabled = enabled
        self.name = name
        self.text = text
        self.mode = mode
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey {
        case id, enabled, name, text, mode, colorHex
        /// Before rules had a mode, each was a JavaScript expression.
        case expression
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? colorHex
        if let mode = try c.decodeIfPresent(SearchMode.self, forKey: .mode) {
            self.mode = mode
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        } else {
            let expression = try c.decodeIfPresent(String.self, forKey: .expression) ?? ""
            text = ProcessExpressions.legacyExpression(in: expression) ?? expression
            mode = .javascript
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(name, forKey: .name)
        try c.encode(text, forKey: .text)
        try c.encode(mode, forKey: .mode)
        try c.encode(colorHex, forKey: .colorHex)
    }
}

/// Row highlighting categories, highest priority first.
enum HighlightRule: String, CaseIterable, Identifiable {
    case keptInView
    case removed
    case new
    case notResponding
    case sensors
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
        case .keptInView: return "Process kept in view"
        case .removed: return "Terminated processes"
        case .new: return "New processes"
        case .notResponding: return "Applications not responding"
        case .sensors: return "Using the microphone, camera or screen recording"
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
        case .keptInView: return NSColor(hex: "#5E5CE6")!
        case .removed: return NSColor(hex: "#FF3C3C")!
        case .new: return NSColor(hex: "#33D17A")!
        case .notResponding: return NSColor(hex: "#B0102A")!
        case .sensors: return NSColor(hex: "#FF7F11")!
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
    /// Background for a process row, or nil. `followed` is the process the list keeps in view.
    static func style(for item: ProcessItem, followed: ProcessKey? = nil, store: ProcessStore = .shared) -> RowStyle? {
        let settings = AppSettings.shared.highlights
        func use(_ rule: HighlightRule) -> RowStyle? {
            guard let s = settings[rule], s.enabled else { return nil }
            let alpha: CGFloat = [.keptInView, .removed, .new, .notResponding].contains(rule) ? 0.55 : 0.28
            return RowStyle(background: s.color.withAlphaComponent(alpha))
        }
        let r = item.record
        if item.key == followed, let s = use(.keptInView) { return s }
        if item.isRemoved, let s = use(.removed) { return s }
        if store.isNew(item), let s = use(.new) { return s }
        // Custom rules, evaluated with each snapshot, come next.
        if let id = item.customHighlight, let rule = AppSettings.shared.customHighlights.first(where: { $0.id == id }), rule.enabled {
            return RowStyle(background: rule.color.withAlphaComponent(0.28))
        }
        if item.isNotResponding, let s = use(.notResponding) { return s }
        if !item.sensors.isEmpty, let s = use(.sensors) { return s }
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
    /// True when any of the persistent process filters, or the focus on a process, is active.
    var hasProcessFilters: Bool {
        onlyApplications || hideOtherUsers || hideSystemProcesses || hideAppleProcesses || hideZombies || onlyNotResponding
            || ProcessSelection.shared.focused != nil
    }

    func resetProcessFilters() {
        ProcessSelection.shared.focus(nil)
        onlyApplications = false
        onlyNotResponding = false
        hideOtherUsers = false
        hideSystemProcesses = false
        hideAppleProcesses = false
        hideZombies = false
    }
}

/// Applications whose responsiveness the window server can judge (any with a connection to it,
/// including menu bar apps), and those of them that aren't responding; see `AppResponsiveness`.
enum ApplicationResponsiveness {
    static func current() -> (checked: Set<Int32>, unresponsive: Set<Int32>) {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier))
        return (pids, AppResponsiveness.unresponsive(among: pids))
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
