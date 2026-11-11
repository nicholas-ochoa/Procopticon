import AppKit
import Combine
import ProcopticonCore
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case services = "Services"
    case network = "Network"
    case disk = "Disk"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .processes: return "list.bullet.indent"
        case .services: return "gearshape.2"
        case .network: return "network"
        case .disk: return "internaldrive"
        }
    }

    var help: String {
        switch self {
        case .processes: return "All running processes with CPU, memory and disk usage"
        case .services: return "launchd daemons, agents and login items, and their state"
        case .network: return "Open TCP and UDP connections and the processes that own them"
        case .disk: return "Processes currently reading from or writing to disk"
        }
    }
}

extension Notification.Name {
    static let showTab = Notification.Name("Procopticon.ShowTab")
    static let focusSearch = Notification.Name("Procopticon.FocusSearch")
}

/// Tab and search state of the main window.
///
/// Not observed by `MainView`: only the views that display this state observe it (and the toolbar,
/// see `MainToolbar`), so switching tabs or typing updates just those.
final class MainWindowState: ObservableObject {
    static let shared = MainWindowState()

    @Published var tab: MainTab {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "mainTab")
            if oldValue != tab, !otherSearch.isEmpty {
                otherSearch = ""
            }
        }
    }
    @Published var processSearch = "" {
        didSet {
            if ProcessStore.shared.filter.text != processSearch {
                ProcessStore.shared.filter.text = processSearch
            }
        }
    }
    @Published var otherSearch = ""
    @Published private(set) var elevationRevision = 0
    private var observers: [NSObjectProtocol] = []
    private var cancellable: AnyCancellable?

    private init() {
        tab = MainTab(rawValue: UserDefaults.standard.string(forKey: "mainTab") ?? "") ?? .processes
        observers.append(NotificationCenter.default.addObserver(forName: .showTab, object: nil, queue: .main) { [weak self] n in
            if let t = n.object as? MainTab, self?.tab != t { self?.tab = t }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Elevation.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.elevationRevision &+= 1
        })
        // Mirror filter text set elsewhere (saved filters, "Go to process") into the search field.
        cancellable = ProcessStore.shared.$revision.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            let text = ProcessStore.shared.filter.text
            if text != self.processSearch {
                self.processSearch = text
            }
        }
    }

    var searchBinding: Binding<String> {
        Binding(
            get: { self.tab == .processes ? self.processSearch : self.otherSearch },
            set: { if self.tab == .processes { self.processSearch = $0 } else { self.otherSearch = $0 } })
    }
}

struct MainView: View {
    var body: some View {
        MainContentView()
            .navigationTitle("Procopticon")
            .background(WindowAccessor(immediately: true) { window in
                window.identifier = NSUserInterfaceItemIdentifier("main")
                window.level = AppSettings.shared.alwaysOnTop ? .floating : .normal
                window.setFrameAutosaveName("MainWindow")
                // The toolbar is AppKit's (see MainToolbar), not a SwiftUI `.toolbar`.
                MainToolbar.shared.install(on: window)
            })
    }
}

/// Window content: the four tabs and the status bar.
struct MainContentView: View {
    @ObservedObject private var state = MainWindowState.shared
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(SummarySection.storageKey) private var summarySection = ""

    var body: some View {
        VStack(spacing: 0) {
            // All tabs stay alive; inactive ones are hidden and pause their updates, so switching
            // tabs is instant instead of rebuilding a large table on the main thread.
            ZStack {
                ProcessTreeView(active: state.tab == .processes)
                tab(.services) { ServicesView(search: $state.otherSearch, active: $0) }
                tab(.network) { NetworkView(search: $state.otherSearch, active: $0) }
                tab(.disk) { DiskView(search: $state.otherSearch, active: $0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // No cross-fade: animating four large tables forces repeated layout and commits.
            .transaction { $0.animation = nil }
            if settings.showStatusBar {
                if let section = SummarySection(rawValue: summarySection) {
                    Divider()
                    StatusSummaryPanel(section: section)
                }
                Divider()
                MainStatusBar()
            }
        }
    }

    private func tab<Content: View>(_ t: MainTab, @ViewBuilder content: (Bool) -> Content) -> some View {
        let active = state.tab == t
        return content(active)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
    }
}

struct MainStatusBar: View {
    @ObservedObject private var state = MainWindowState.shared
    @ObservedObject private var store = ProcessStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        StatusBarView(elevationRevision: state.elevationRevision,
                      searchError: state.tab == .processes ? store.filterError : settings.matcher(state.otherSearch).error,
                      showFilterSummary: state.tab == .processes)
    }
}

struct StatusBarView: View {
    @ObservedObject private var store = ProcessStore.shared
    @AppStorage(SummarySection.storageKey) private var summarySection = ""
    var elevationRevision: Int
    var searchError: String?
    var showFilterSummary = false

    var body: some View {
        let sys = store.system
        let vm = sys.last?.vm
        HStack(spacing: 6) {
            sectionButton(.cpu) {
                stat("CPU", String(format: "%.1f%%", sys.cpuUsage))
                if let load = sys.last?.loadAverage, !load.isEmpty {
                    stat("Load", load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " "))
                }
                stat("Processes", "\(store.processCount)")
                stat("Threads", Fmt.count(store.totalThreads))
            }
            if let vm {
                sectionButton(.memory) {
                    stat("Memory", "\(Fmt.bytes(vm.usedBytes)) / \(Fmt.bytes(vm.totalBytes)) (\(String(format: "%.0f%%", Double(vm.usedBytes) / Double(max(1, vm.totalBytes)) * 100)))")
                    stat("Swap", Fmt.bytes(vm.swapUsed))
                    stat("Pressure", vm.pressureDescription)
                }
            }
            sectionButton(.disk) {
                stat("Disk", "↓\(Fmt.rate(sys.diskReadRate).ifEmpty("0")) ↑\(Fmt.rate(sys.diskWriteRate).ifEmpty("0"))")
            }
            sectionButton(.network) {
                stat("Network", "↓\(Fmt.rate(sys.netInRate).ifEmpty("0")) ↑\(Fmt.rate(sys.netOutRate).ifEmpty("0"))")
            }
            if !sys.gpu.ordered.isEmpty {
                sectionButton(.gpu) {
                    stat("GPU", String(format: "%.0f%%", sys.gpu.last))
                }
            }
            Spacer()
            // Without this the list just stops changing, and looks current.
            if let error = store.lastError {
                Label("Not updating", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("The process list couldn't be refreshed, so it shows what was last read. \(error)")
            }
            if showFilterSummary, store.filter.isFiltering {
                if let saved = AppSettings.shared.activeSavedFilter {
                    Label(saved.name, systemImage: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.secondary)
                }
                if let key = store.filter.focus {
                    Label("\(store.item(key)?.name ?? "Process") (\(key.pid))", systemImage: "viewfinder")
                        .foregroundStyle(.secondary)
                        .help("Only this process and its descendants are shown. Choose Focus again on it, or Clear Filters, to show every process.")
                }
                Text("Showing \(Fmt.count(store.matchCount)) of \(Fmt.count(store.processCount)) processes")
                    .foregroundStyle(.secondary)
                Button("Clear Filters") {
                    AppSettings.shared.resetProcessFilters()
                    store.filter.text = ""
                }
                .controlSize(.small)
                .buttonStyle(.link)
                .help("Clear the search and turn off every filter, showing all processes")
            }
            if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .help(searchError)
            }
            if store.paused {
                Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
            }
            modeLabel
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var modeLabel: some View {
        _ = elevationRevision
        let mode = Elevation.shared.mode
        return Label(mode == .helper ? "Elevated" : mode.rawValue, systemImage: mode == .standard ? "person" : "shield.lefthalf.filled")
            .foregroundStyle(mode == .standard ? Color.secondary : Color.orange)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title + ":").foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// A group of stats that opens (or closes) its section of the summary panel.
    private func sectionButton<Content: View>(_ section: SummarySection, @ViewBuilder content: () -> Content) -> some View {
        let open = summarySection == section.rawValue
        return Button {
            summarySection = open ? "" : section.rawValue
        } label: {
            HStack(spacing: 14) { content() }
        }
        .buttonStyle(StatusSectionButtonStyle(isOpen: open))
        .help(open ? "Hide the \(section.rawValue) details" : "Show \(section.rawValue) details above the status bar")
    }
}

/// Status bar stats that open a section of the summary panel: a hover highlight, and a tinted
/// capsule while their section is open.
private struct StatusSectionButtonStyle: ButtonStyle {
    var isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        StatusSectionCell(label: configuration.label, isPressed: configuration.isPressed, isOpen: isOpen)
    }
}

private struct StatusSectionCell<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isOpen: Bool
    @State private var hovering = false

    var body: some View {
        label
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(isOpen ? AnyShapeStyle(.tint.opacity(0.22))
                               : AnyShapeStyle(.primary.opacity(isPressed ? 0.14 : hovering ? 0.07 : 0)))
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// Gives access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    /// Configure the window as the view joins it, before it is shown, instead of a moment later:
    /// for what changes how the window looks (its toolbar).
    var immediately = false
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView()
        if immediately {
            view.onWindow = configure
        } else {
            DispatchQueue.main.async {
                if let w = view.window { configure(w) }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowAttachmentView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, let onWindow {
            self.onWindow = nil
            onWindow(window)
        }
    }
}

/// Native search field with a ".*" regular-expression toggle at its trailing edge, used for the
/// toolbar search and the filter fields above lists.
struct RegexSearchFieldView: NSViewRepresentable {
    @Binding var text: String
    @Binding var regex: Bool
    /// When given, a {} toggle for JavaScript expressions (the process search).
    var javaScript: Binding<Bool>?
    var prompt: String
    var toolTip: String?
    /// The search is invalid (e.g. a malformed regular expression); the toggle turns red.
    var isInvalid = false
    /// Find (⌘F) focuses this field.
    var focusOnFind = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RegexSearchField {
        makeField(coordinator: context.coordinator)
    }

    func updateNSView(_ field: RegexSearchField, context: Context) {
        apply(to: field, coordinator: context.coordinator)
    }

    /// The field, wired to `coordinator`. Also for the main toolbar, which is AppKit's and has no
    /// SwiftUI context to make one in.
    @MainActor
    func makeField(coordinator: Coordinator) -> RegexSearchField {
        let field = RegexSearchField()
        field.delegate = coordinator
        field.regexButton.target = coordinator
        field.regexButton.action = #selector(Coordinator.toggleRegex(_:))
        field.javaScriptButton.target = coordinator
        field.javaScriptButton.action = #selector(Coordinator.toggleJavaScript(_:))
        field.isRegex = regex
        field.showsJavaScript = javaScript != nil
        field.isJavaScript = javaScript?.wrappedValue ?? false
        field.isInvalid = isInvalid
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.placeholder = prompt
        field.stringValue = text
        field.toolTip = toolTip
        coordinator.field = field
        coordinator.startCompleting()
        if focusOnFind {
            coordinator.focusObserver = NotificationCenter.default.addObserver(
                forName: .focusSearch, object: nil, queue: .main) { [weak field] _ in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }

    /// Brings `field` in line with this description of it.
    @MainActor
    func apply(to field: RegexSearchField, coordinator: Coordinator) {
        coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.isRegex != regex {
            field.isRegex = regex
        }
        if field.showsJavaScript != (javaScript != nil) {
            field.showsJavaScript = javaScript != nil
        }
        if field.isJavaScript != (javaScript?.wrappedValue ?? false) {
            field.isJavaScript = javaScript?.wrappedValue ?? false
            coordinator.completer.hide()
        }
        if field.isInvalid != isInvalid {
            field.isInvalid = isInvalid
        }
        if field.placeholder != prompt {
            field.placeholder = prompt
        }
        if field.toolTip != toolTip {
            field.toolTip = toolTip
        }
    }

    static func dismantleNSView(_ field: RegexSearchField, coordinator: Coordinator) {
        coordinator.stopCompleting()
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: RegexSearchFieldView
        var focusObserver: NSObjectProtocol?
        weak var field: RegexSearchField?
        /// Completions for a JavaScript search, in the field editor while the field edits.
        private(set) lazy var completer = ExpressionCompleter(
            textView: { [weak self] in self?.field?.currentEditor() as? NSTextView },
            isEnabled: { [weak self] in self?.parent.javaScript?.wrappedValue == true })
        private var keyMonitor: Any?
        private var selectionObserver: NSObjectProtocol?

        init(_ parent: RegexSearchFieldView) {
            self.parent = parent
        }

        deinit {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        /// Watches for ⌃Space and caret moves while the field edits. The field editor is the
        /// window's, so this goes through a key monitor and notifications rather than a subclass.
        func startCompleting() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = ExpressionCompleter.isRequest(event) && MainActor.assumeIsolated {
                    guard let self, let field = self.field, event.window === field.window, field.currentEditor() != nil else {
                        return false
                    }
                    return self.completer.request()
                }
                return handled ? nil : event
            }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    if let self, let editor = n.object as? NSTextView, editor === self.field?.currentEditor() {
                        self.completer.selectionDidChange()
                    }
                }
            }
        }

        func stopCompleting() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            keyMonitor = nil
            selectionObserver = nil
            completer.hide()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
            completer.textDidChange()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            completer.hide()
        }

        @objc func toggleRegex(_ sender: NSButton) {
            parent.regex = sender.state == .on
        }

        @objc func toggleJavaScript(_ sender: NSButton) {
            parent.javaScript?.wrappedValue = sender.state == .on
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // The completion list's keys come first; with no list, Esc still clears the search.
            if completer.handle(selector, escapeRequests: false) {
                return true
            }
            // Escape clears the search, like the standard toolbar search field.
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                (control as? NSSearchField)?.stringValue = ""
                parent.text = ""
                return true
            }
            return false
        }
    }
}

/// Search field with a ".*" toggle (and optionally a "{}" one for JavaScript) inside its trailing
/// edge. The cell narrows the text area and moves the clear button left so they don't overlap.
final class RegexSearchField: NSSearchField {
    let regexButton = NSButton(title: ".*", target: nil, action: nil)
    let javaScriptButton = NSButton(title: "{}", target: nil, action: nil)

    override class var cellClass: AnyClass? {
        get { RegexSearchFieldCell.self }
        set {}
    }

    var isRegex = false {
        didSet { updateButtons() }
    }

    var isJavaScript = false {
        didSet { updateButtons() }
    }

    var showsJavaScript = false {
        didSet {
            javaScriptButton.isHidden = !showsJavaScript
            updateButtons()
            needsLayout = true
            needsDisplay = true
        }
    }

    var isInvalid = false {
        didSet { updateButtons() }
    }

    /// The placeholder, always in the fixed-width font, so it doesn't change with the text's font
    /// as the mode does.
    var placeholder: String {
        get { placeholderAttributedString?.string ?? "" }
        set {
            placeholderAttributedString = NSAttributedString(string: newValue, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: font?.pointSize ?? NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.placeholderTextColor,
            ])
        }
    }

    /// The toggles inside the trailing edge.
    var accessoryCount: Int { showsJavaScript ? 2 : 1 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [regexButton, javaScriptButton] {
            button.setButtonType(.pushOnPushOff)
            button.isBordered = false
            button.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            addSubview(button)
        }
        regexButton.setAccessibilityLabel("Regular expression")
        javaScriptButton.setAccessibilityLabel("JavaScript expression")
        javaScriptButton.isHidden = true
        updateButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // Search text is matched literally: no curly quotes or dashes in `user == "root"`.
        if became, let editor = currentEditor() as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
        return became
    }

    override func layout() {
        super.layout()
        let width = RegexSearchFieldCell.accessoryWidth
        regexButton.frame = NSRect(x: bounds.maxX - width - 6, y: bounds.minY, width: width, height: bounds.height)
        javaScriptButton.frame = regexButton.frame.offsetBy(dx: -width, dy: 0)
        fitEditor()
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        editorChanged()
    }

    /// The text being edited or its font changed, or editing has just begun.
    func editorChanged() {
        fitEditor()
    }

    /// Keeps the end of a long line from being cut off while it is edited.
    ///
    /// The field editor is given the width of the text area and keeps it; what is typed past that
    /// width lies beyond the editor's edge and isn't drawn, however far the visible part scrolls.
    /// (The cell's narrower text area, which makes room for the toggles, made that happen sooner.)
    /// So the editor is kept as wide as its text, and the visible part scrolls to the insertion point.
    func fitEditor() {
        guard let editor = currentEditor() as? NSTextView, let visible = editor.superview, visible.superview === self else { return }
        let font = editor.font ?? self.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let text = (editor.string as NSString).size(withAttributes: [.font: font]).width
        let padding = 2 * ((editor.textContainer?.lineFragmentPadding ?? 5) + editor.textContainerInset.width)
        // A little more than the text, for the insertion point after its last character.
        let wanted = max(visible.frame.width, (text + padding).rounded(.up) + 2)
        guard abs(editor.frame.width - wanted) > 0.5 else { return }
        editor.setFrameSize(NSSize(width: wanted, height: editor.frame.height))
        editor.scrollRangeToVisible(editor.selectedRange())
    }

    private func updateButtons() {
        regexButton.state = isRegex ? .on : .off
        regexButton.contentTintColor = isInvalid && isRegex ? .systemRed : isRegex ? .controlAccentColor : .secondaryLabelColor
        regexButton.toolTip = isRegex
            ? "Search text is a regular expression. Click for plain text matching (⌥⌘R)"
            : "Treat search text as a regular expression (⌥⌘R)"
        let javaScript = showsJavaScript && isJavaScript
        javaScriptButton.state = javaScript ? .on : .off
        javaScriptButton.contentTintColor = isInvalid && javaScript ? .systemRed : javaScript ? .controlAccentColor : .secondaryLabelColor
        javaScriptButton.toolTip = javaScript
            ? "Search text is a JavaScript expression over each process's values. Click for plain text matching (⌥⌘J)"
            : "Search with a JavaScript expression, such as cpu > 10 && user == \"root\" (⌥⌘J)"
        // Patterns and code read better in a fixed-width font.
        let size = self.font?.pointSize ?? NSFont.systemFontSize
        let font: NSFont = isRegex || javaScript
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        if self.font != font {
            self.font = font
            (currentEditor() as? NSTextView)?.font = font
        }
        editorChanged()
    }
}

final class RegexSearchFieldCell: NSSearchFieldCell {
    static let accessoryWidth: CGFloat = 24

    private var accessoriesWidth: CGFloat {
        Self.accessoryWidth * CGFloat((controlView as? RegexSearchField)?.accessoryCount ?? 1)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchTextRect(forBounds: rect)
        r.size.width -= accessoriesWidth
        return r
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.cancelButtonRect(forBounds: rect)
        r.origin.x -= accessoriesWidth
        return r
    }

    // Editing starts through one of these two; see `RegexSearchField.editorChanged`.
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        (controlView as? RegexSearchField)?.editorChanged()
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
        (controlView as? RegexSearchField)?.editorChanged()
    }

    // The field's accessibility element is this cell, which lists only the search and clear buttons;
    // add the toggle so VoiceOver can reach it.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let field = controlView as? RegexSearchField {
            for button in field.showsJavaScript ? [field.javaScriptButton, field.regexButton] : [field.regexButton] {
                if let toggle = NSAccessibility.unignoredDescendant(of: button) {
                    children.append(toggle)
                }
            }
        }
        return children
    }
}

