import AppKit
import ProcopticonExpressions
import SwiftUI

/// The list of completions under the caret in a JavaScript `CodeEditor`: a borderless child window
/// of the editor's window, which never takes the keyboard focus from the editor. The editor moves
/// the selection and accepts items; a click accepts one too.
@MainActor
final class CompletionPopup {
    private(set) var completion: ExpressionCompletion?
    private(set) var selection = 0
    /// Called with an item that was clicked.
    var onPick: (ExpressionCompletion.Item) -> Void = { _ in }

    static let rowHeight: CGFloat = 22
    static let maxRows = 8
    static let width: CGFloat = 400
    static let footerHeight: CGFloat = 40
    /// From the panel's leading edge to where an item's name starts, to line the names up with the word.
    static let nameInset: CGFloat = 4 + 8 + 16 + 6

    private lazy var host = FirstMouseHostingView(rootView: CompletionList(items: [], prefix: "", selection: 0, onPick: { _ in }))
    private lazy var panel: NSPanel = {
        let panel = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.contentView = host
        return panel
    }()

    var isVisible: Bool { completion != nil }

    var selectedItem: ExpressionCompletion.Item? {
        guard let items = completion?.items, items.indices.contains(selection) else { return nil }
        return items[selection]
    }

    /// Shows `completion` below `caret` (a screen rectangle), or above it when there's no room.
    func show(_ completion: ExpressionCompletion, below caret: NSRect, in window: NSWindow) {
        // The selected item stays selected while it's still offered.
        let selected = selectedItem?.id
        selection = completion.items.firstIndex { $0.id == selected } ?? 0
        self.completion = completion
        render()

        let rows = CGFloat(min(completion.items.count, Self.maxRows))
        let size = NSSize(width: Self.width, height: rows * Self.rowHeight + 8 + 1 + Self.footerHeight)
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = NSPoint(x: caret.minX - Self.nameInset, y: caret.minY - size.height - 3)
        if origin.y < screen.minY {
            origin.y = caret.maxY + 3
        }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func hide() {
        guard completion != nil else { return }
        completion = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Moves the selection by `delta` rows, stopping at either end.
    func move(_ delta: Int) {
        guard let count = completion?.items.count, count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
        render()
    }

    private func render() {
        host.rootView = CompletionList(items: completion?.items ?? [], prefix: completion?.prefix ?? "", selection: selection,
                                       onPick: { [weak self] in self?.onPick($0) })
    }
}

/// Never becomes key, so the editor keeps the focus.
private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, though its window is never key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CompletionList: View {
    let items: [ExpressionCompletion.Item]
    let prefix: String
    let selection: Int
    let onPick: (ExpressionCompletion.Item) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selection)
                                .id(item.id)
                                .onTapGesture { onPick(item) }
                        }
                    }
                    .padding(4)
                }
                .onChange(of: selection) { _, selection in
                    if items.indices.contains(selection) {
                        proxy.scrollTo(items[selection].id)
                    }
                }
            }
            Divider()
            Text(items.indices.contains(selection) ? items[selection].help : "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(height: CompletionPopup.footerHeight)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row(_ item: ExpressionCompletion.Item, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(badge(item.kind))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color(nsColor: color(item.kind)), in: RoundedRectangle(cornerRadius: 4))
            Text(label(item))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: CompletionPopup.rowHeight)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    /// The label with the part matching what was typed in bold.
    private func label(_ item: ExpressionCompletion.Item) -> AttributedString {
        var text = AttributedString(item.label)
        if !prefix.isEmpty, let range = text.range(of: prefix, options: .caseInsensitive) {
            text[range].font = .system(size: 12, weight: .bold, design: .monospaced)
        }
        return text
    }

    private func badge(_ kind: ExpressionCompletion.Item.Kind) -> String {
        switch kind {
        case .field: return "V"
        case .constant: return "C"
        case .keyword: return "K"
        case .global: return "O"
        case .property: return "P"
        case .method: return "M"
        }
    }

    /// The colors the editor gives the same kinds of word.
    private func color(_ kind: ExpressionCompletion.Item.Kind) -> NSColor {
        switch kind {
        case .field: return .systemTeal
        case .constant: return .systemPurple
        case .keyword: return .systemPink
        case .global: return .systemGray
        case .property, .method: return .systemIndigo
        }
    }
}

/// Offers completions in a text view holding a JavaScript process expression: shows a
/// `CompletionPopup` as the word at the caret changes, handles the keys that choose and accept an
/// item, and replaces the word with it. Works with an editor's own text view, or a search field's
/// field editor while it edits.
@MainActor
final class ExpressionCompleter {
    private let popup = CompletionPopup()
    private let textView: () -> NSTextView?
    /// Whether the text is a JavaScript expression just now.
    private let isEnabled: () -> Bool
    /// The list was asked for (⌃Space, Esc), so it shows for an empty word too.
    private var requested = false
    /// Set while accepting an item, so the edit doesn't open the list again.
    private var accepting = false
    private var observers: [NSObjectProtocol] = []

    init(textView: @escaping () -> NSTextView?, isEnabled: @escaping () -> Bool) {
        self.textView = textView
        self.isEnabled = isEnabled
        popup.onPick = { [weak self] in self?.accept($0) }
        // The list stays under the caret only while nothing moves the text or takes its window's focus.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if let self, self.popup.isVisible, n.object as? NSWindow === self.textView()?.window { self.hide() }
            }
        })
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if let self, self.popup.isVisible, (n.object as? NSView)?.window === self.textView()?.window { self.hide() }
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isShowing: Bool { popup.isVisible }

    /// After the text changed: typing a letter, digit or dot offers completions, and any edit
    /// updates a list that's showing.
    func textDidChange() {
        guard !accepting else { return }
        if popup.isVisible || Self.typedWordCharacter() {
            update()
        }
    }

    /// After the caret moved: moving it out of the word closes the list.
    func selectionDidChange() {
        if popup.isVisible, !accepting {
            update()
        }
    }

    func hide() {
        popup.hide()
        requested = false
    }

    /// Shows everything that fits at the caret, even for an empty word. False when completions
    /// don't apply.
    @discardableResult
    func request() -> Bool {
        guard isEnabled(), textView() != nil else { return false }
        requested = true
        update()
        return true
    }

    /// The list's keys while it shows (↑ ↓ to choose, Tab or Return to accept, Esc to close); while
    /// it doesn't, Tab completes the word being typed, and with `escapeRequests` Esc asks for the
    /// list. Returns whether it handled `selector`.
    func handle(_ selector: Selector, escapeRequests: Bool) -> Bool {
        guard isEnabled(), let textView = textView() else { return false }
        if popup.isVisible {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): popup.move(-1)
            case #selector(NSResponder.moveDown(_:)): popup.move(1)
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): popup.move(-CompletionPopup.maxRows)
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): popup.move(CompletionPopup.maxRows)
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                if let item = popup.selectedItem { accept(item) }
            case #selector(NSResponder.cancelOperation(_:)): hide()
            default: return false
            }
            return true
        }
        switch selector {
        case #selector(NSResponder.complete(_:)):
            return request()
        case #selector(NSResponder.cancelOperation(_:)) where escapeRequests:
            return request()
        case #selector(NSResponder.insertTab(_:)):
            // Tab completes the word being typed: at once when only one thing fits. With no word,
            // it moves on as usual.
            guard textView.selectedRange().length == 0,
                  let completion = ExpressionCompletion.at(textView.selectedRange().location, in: textView.string) else {
                return false
            }
            if completion.items.count == 1 {
                accept(completion.items[0], replacing: completion.range)
            } else {
                update()
            }
            return true
        default:
            return false
        }
    }

    /// Shows, updates or hides the list for the word at the caret.
    private func update() {
        guard isEnabled(), let textView = textView(), let window = textView.window,
              window.firstResponder === textView, textView.selectedRange().length == 0,
              let completion = ExpressionCompletion.at(textView.selectedRange().location, in: textView.string,
                                                       explicit: requested) else {
            hide()
            return
        }
        let caret = textView.firstRect(forCharacterRange: NSRange(location: completion.range.location, length: 0), actualRange: nil)
        popup.show(completion, below: caret, in: window)
    }

    /// Replaces the word with `item` (in `range`, or the list's word).
    private func accept(_ item: ExpressionCompletion.Item, replacing range: NSRange? = nil) {
        guard let textView = textView(), let range = range ?? popup.completion?.range else { return }
        let insertion = item.insertion
        accepting = true
        textView.insertText(insertion.text, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + insertion.caret, length: 0))
        accepting = false
        hide()
    }

    /// Whether the key being handled typed a letter, digit, "_", "$" or "." (not a paste or a
    /// deletion), which a completion can follow.
    private static func typedWordCharacter() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let c = event.characters?.last else { return false }
        return c.isLetter || c.isNumber || c == "_" || c == "$" || c == "."
    }

    /// Whether `event` is ⌃Space, the usual key for asking for completions.
    nonisolated static func isRequest(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
    }
}
