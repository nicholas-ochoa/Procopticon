import AppKit
import InformerCore
import SwiftUI
import UniformTypeIdentifiers

/// Creates and tracks auxiliary windows (properties, reports, tools) hosted with SwiftUI content.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    @discardableResult
    func show<Content: View>(id: String, title: String, size: NSSize = NSSize(width: 720, height: 560),
                             autosave: String? = nil, @ViewBuilder content: () -> Content) -> NSWindow {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = NSHostingController(rootView: content().environmentObject(AppSettings.shared))
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        if let autosave {
            window.setFrameAutosaveName(autosave)
        }
        if windows.isEmpty || autosave == nil {
            window.center()
        }
        if let key = NSApp.keyWindow, autosave == nil {
            let origin = NSPoint(x: key.frame.minX + 40, y: key.frame.maxY - 40 - window.frame.height)
            window.setFrameOrigin(origin)
            window.cascadeTopLeft(from: NSPoint(x: origin.x, y: window.frame.maxY))
        }
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let entry = windows.first(where: { $0.value === window }) {
            windows.removeValue(forKey: entry.key)
        }
    }
}

@MainActor
enum Alerts {
    /// Returns true if confirmed. Honors the "confirm actions" preference when `suppressible`.
    static func confirm(_ title: String, message: String, button: String, destructive: Bool = true, suppressible: Bool = true) -> Bool {
        if suppressible, !AppSettings.shared.confirmActions {
            return true
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        let ok = alert.addButton(withTitle: button)
        ok.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        if suppressible {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }
        let result = alert.runModal() == .alertFirstButtonReturn
        if result, suppressible, alert.suppressionButton?.state == .on {
            AppSettings.shared.confirmActions = false
        }
        return result
    }

    static func error(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    static func info(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    static func prompt(_ title: String, message: String, defaultValue: String = "", button: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func save(text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Alerts.error("Unable to save", error.localizedDescription)
        }
    }
}

/// Monospaced text report (tool output, sample, vmmap, plist contents...).
struct TextReportView: View {
    let title: String
    let loader: () async -> String
    @State private var text = ""
    @State private var loading = true
    @State private var search = ""
    @State private var filtered = ""
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Collecting…").foregroundStyle(.secondary)
                }
                Spacer()
                FilterField($search, prompt: "Filter lines", width: 220)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Save…") {
                    Alerts.save(text: text, suggestedName: title.replacingOccurrences(of: "/", with: "-") + ".txt")
                }
                Button("Refresh") { Task { await load() } }
            }
            .padding(8)
            Divider()
            MonospacedTextView(text: filtered)
        }
        .task { await load() }
        .task(id: FilterKey(search: search, regex: settings.searchUsesRegex, length: text.count)) {
            // Large outputs (spindump, vmmap) are filtered off the main thread.
            let m = settings.matcher(search)
            let source = text
            let result = await Task.detached { () -> String in
                guard !m.isEmpty else { return source }
                return source.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { m.matches(String($0)) }
                    .joined(separator: "\n")
            }.value
            if !Task.isCancelled {
                filtered = result
            }
        }
    }

    private struct FilterKey: Hashable {
        var search: String
        var regex: Bool
        var length: Int
    }

    private func load() async {
        loading = true
        text = await loader()
        loading = false
    }
}

/// Read-only NSTextView (fast for large outputs, selectable, find bar).
struct MonospacedTextView: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 200)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}

@MainActor
enum Reports {
    static func show(title: String, id: String? = nil, loader: @escaping () async -> String) {
        WindowManager.shared.show(id: id ?? "report-\(UUID().uuidString)", title: title, size: NSSize(width: 820, height: 600)) {
            TextReportView(title: title, loader: loader)
        }
    }

    /// Runs an allowed tool, elevating if `requiresRoot`, and returns combined output.
    static func runTool(_ tool: String, _ args: [String], requiresRoot: Bool) async -> String {
        let response = await Elevation.shared.performElevated(.runTool(tool: tool, arguments: args), requiresRoot: requiresRoot)
        switch response {
        case .tool(let out):
            if out.status != 0, out.stdout.isEmpty {
                return "\((tool as NSString).lastPathComponent) exited with status \(out.status)\n\n" + out.stderr
            }
            return out.combined
        case .failure(let e):
            return "Error: \(e.message)"
        default:
            return ""
        }
    }
}
