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
