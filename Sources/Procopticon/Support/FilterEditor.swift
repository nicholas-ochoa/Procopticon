import AppKit
import ProcopticonCore
import ProcopticonExpressions
import SwiftUI

/// Filter text and how it matches: tabs for Text, Regex and JavaScript above a monospaced,
/// syntax-colored editor, and what the filter matches among the running processes.
struct FilterEditor: View {
    @Binding var text: String
    @Binding var mode: SearchMode
    /// Said while the filter is empty, e.g. that it then matches every process.
    var emptyStatus: String
    @State private var outcome = ExpressionCheck.Outcome()

    private struct CheckKey: Equatable {
        var text: String
        var mode: SearchMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Match as", selection: $mode) {
                    ForEach(SearchMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Match the text anywhere, as a regular expression, or as a JavaScript expression over the process's values")
                Spacer()
                FilterReferenceButton(mode: mode)
            }
            CodeEditor(text: $text, mode: mode, placeholder: mode.placeholder)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(emptyStatus).font(.caption).foregroundStyle(.secondary)
            } else {
                ExpressionStatus(outcome: outcome)
            }
        }
        // Text and regular expressions are one line.
        .onChange(of: mode) { _, newMode in
            if newMode != .javascript, text.contains(where: \.isNewline) {
                text = text.components(separatedBy: .newlines).joined(separator: " ")
            }
        }
        // Checked when the filter changes rather than at every sample, so the form isn't rebuilt
        // each second while you type.
        .task(id: CheckKey(text: text, mode: mode)) { outcome = ExpressionCheck.search(text, mode: mode) }
    }
}

extension SearchMode {
    var placeholder: String {
        switch self {
        case .text: return "Name, PID, path, command line, user or bundle ID"
        case .regex: return "^com\\.apple\\.(Safari|Mail)$"
        case .javascript: return "cpu > 50 && memory > 2 * GB"
        }
    }
}

/// A monospaced editor for filter text, colored for its mode. Text and regular expressions stay on
/// one line (Return ends editing); a JavaScript expression may span several, and gets completions
/// as you type (see `ExpressionCompletion`): ↑ and ↓ choose, Tab or Return accepts, Esc dismisses
/// the list or, with none showing, asks for one.
struct CodeEditor: View {
    @Binding var text: String
    var mode: SearchMode
    var placeholder: String
    @State private var focused = false

    var body: some View {
        CodeTextView(text: $text, mode: mode, focused: $focused)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Font(CodeTextView.font))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, CodeTextView.inset.width + CodeTextView.linePadding)
                        .padding(.top, CodeTextView.inset.height)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay {
                // A focus ring like a text field's.
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(focused ? 0.5 : 0), lineWidth: 3)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// The text view inside `CodeEditor`.
private struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var mode: SearchMode
    @Binding var focused: Bool

    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let inset = NSSize(width: 4, height: 4)
    static let linePadding: CGFloat = 2
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeNSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            if !focused {
                coordinator?.hideCompletions()
            }
            // Not during the view update that may have moved the focus.
            DispatchQueue.main.async { coordinator?.parent.focused = focused }
        }
        textView.font = Self.font
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.textContainer?.lineFragmentPadding = Self.linePadding
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Filter")
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let modeChanged = coordinator.parent.mode != mode
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            // Another filter's text (or one changed elsewhere): the edits so far don't apply to it.
            textView.string = text
            coordinator.undoManager.removeAllActions()
            coordinator.hideCompletions()
            coordinator.highlight()
        } else if modeChanged {
            coordinator.hideCompletions()
            coordinator.highlight()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.hideCompletions()
    }

    /// As tall as the text, within a few lines (JavaScript gets room for more, and three to begin with).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let textWidth = max(10, width - 2 * (Self.inset.width + Self.linePadding))
        var height = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Self.font]).height
        if text.hasSuffix("\n") {
            height += Self.lineHeight
        }
        let lines = mode == .javascript ? 3.0...8.0 : 1.0...4.0
        height = min(max(height, lines.lowerBound * Self.lineHeight), lines.upperBound * Self.lineHeight)
        return CGSize(width: width, height: ceil(height + 2 * Self.inset.height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        weak var textView: NSTextView?
        /// The editor's own, rather than the window's it shares with every other field.
        let undoManager = UndoManager()
        private let completions = CompletionPopup()
        /// The last edit typed a letter, digit or dot, which a completion can follow. Deleting only
        /// updates a list that's showing.
        private var typedWord = false
        /// The list was asked for (Esc), so it shows for an empty word too.
        private var completionsRequested = false
        /// Set while accepting a completion, so the edit doesn't open the list again.
        private var accepting = false
        private var observers: [NSObjectProtocol] = []

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        init(_ parent: CodeTextView) {
            self.parent = parent
            super.init()
            completions.onPick = { [weak self] in self?.accept($0) }
            // The list stays under the caret only while nothing moves the editor or its window's focus.
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    if let self, n.object as? NSWindow === self.textView?.window { self.hideCompletions() }
                }
            })
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    if let self, (n.object as? NSView)?.window === self.textView?.window { self.hideCompletions() }
                }
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            highlight()
            parent.text = textView.string
            if accepting {
                return
            }
            if completions.isVisible || typedWord {
                updateCompletions()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Moving the caret out of the word closes the list.
            if completions.isVisible, !accepting {
                updateCompletions()
            }
        }

        // MARK: Completions

        func hideCompletions() {
            completions.hide()
            completionsRequested = false
        }

        /// Shows (or updates, or hides) the completions for the word at the caret.
        private func updateCompletions() {
            guard parent.mode == .javascript, let textView, let window = textView.window,
                  window.firstResponder === textView, textView.selectedRange().length == 0,
                  let completion = ExpressionCompletion.at(textView.selectedRange().location, in: textView.string,
                                                           explicit: completionsRequested) else {
                hideCompletions()
                return
            }
            let caret = textView.firstRect(forCharacterRange: NSRange(location: completion.range.location, length: 0), actualRange: nil)
            completions.show(completion, below: caret, in: window)
        }

        /// Replaces the word with `item` (in `range`, or the list's word).
        private func accept(_ item: ExpressionCompletion.Item, replacing range: NSRange? = nil) {
            guard let textView, let range = range ?? completions.completion?.range else { return }
            let insertion = item.insertion
            accepting = true
            textView.insertText(insertion.text, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + insertion.caret, length: 0))
            accepting = false
            hideCompletions()
        }

        /// Keys for the list while it shows, and Tab and Esc to complete while it doesn't.
        private func handleCompletionCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
            if completions.isVisible {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): completions.move(-1)
                case #selector(NSResponder.moveDown(_:)): completions.move(1)
                case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): completions.move(-CompletionPopup.maxRows)
                case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): completions.move(CompletionPopup.maxRows)
                case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                    if let item = completions.selectedItem { accept(item) }
                case #selector(NSResponder.cancelOperation(_:)): hideCompletions()
                default: return false
                }
                return true
            }
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                completionsRequested = true
                updateCompletions()
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab completes the word being typed: at once when only one thing fits. With no
                // word, it moves on to the next field as usual.
                guard textView.selectedRange().length == 0,
                      let completion = ExpressionCompletion.at(textView.selectedRange().location, in: textView.string) else {
                    return false
                }
                if completion.items.count == 1 {
                    accept(completion.items[0], replacing: completion.range)
                } else {
                    updateCompletions()
                }
                return true
            default:
                return false
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if parent.mode == .javascript, handleCompletionCommand(selector, in: textView) {
                return true
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)) where parent.mode != .javascript:
                textView.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            typedWord = replacementString?.last.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "." } ?? false
            // On one line, pasted line breaks become spaces.
            guard parent.mode != .javascript, let replacement = replacementString,
                  replacement.contains(where: \.isNewline) else { return true }
            textView.insertText(replacement.components(separatedBy: .newlines).joined(separator: " "), replacementRange: range)
            return false
        }

        /// Colors the text for the mode. Only attributes change, so nothing goes on the undo stack.
        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let base: [NSAttributedString.Key: Any] = [.font: CodeTextView.font, .foregroundColor: NSColor.textColor]
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            for token in SyntaxHighlighting.tokens(storage.string, mode: parent.mode, fields: ProcessExpressions.fieldNames,
                                                   constants: ProcessExpressions.constantNames) {
                storage.addAttributes(SyntaxStyle.attributes(token.kind), range: token.range)
            }
            storage.endEditing()
            textView.typingAttributes = base
        }
    }
}

/// Reports when it gains or loses the keyboard focus.
private final class CodeNSTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// Colors for syntax tokens, from the system palette so they suit light and dark mode.
enum SyntaxStyle {
    private static let bold = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    static func attributes(_ kind: SyntaxToken.Kind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .keyword: return [.foregroundColor: NSColor.systemPink, .font: bold]
        case .string: return [.foregroundColor: NSColor.systemRed]
        case .number: return [.foregroundColor: NSColor.systemBlue]
        case .comment: return [.foregroundColor: NSColor.secondaryLabelColor]
        case .field: return [.foregroundColor: NSColor.systemTeal]
        case .constant: return [.foregroundColor: NSColor.systemPurple]
        case .property: return [.foregroundColor: NSColor.systemIndigo]
        case .regexDelimiter, .regexEscape: return [.foregroundColor: NSColor.systemOrange]
        case .regexClass, .regexWildcard: return [.foregroundColor: NSColor.systemGreen]
        case .regexGroup: return [.foregroundColor: NSColor.systemBlue, .font: bold]
        case .regexQuantifier: return [.foregroundColor: NSColor.systemPurple]
        case .regexAnchor, .regexAlternation: return [.foregroundColor: NSColor.systemPink, .font: bold]
        case .error: return [.foregroundColor: NSColor.systemRed, .backgroundColor: NSColor.systemRed.withAlphaComponent(0.2)]
        }
    }
}

/// The round help button: what the current mode matches and how to write it.
struct FilterReferenceButton: View {
    var mode: SearchMode
    @State private var showing = false

    var body: some View {
        HelpLink { showing.toggle() }
            .controlSize(.small)
            .help(mode == .javascript ? "Show the values and examples expressions can use" : "Show how \(mode.title.lowercased()) filters match")
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                switch mode {
                case .text: TextFilterReference().frame(width: 380)
                case .regex: RegexReference().frame(width: 440)
                case .javascript: ExpressionReference().frame(width: 580, height: 540)
                }
            }
    }
}

private struct TextFilterReference: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text").font(.headline)
            Text("""
                Matches processes whose name, path, command line, title, user, app name or bundle ID contains \
                the text, ignoring case, or whose PID is the number.
                """)
            Text("Text written as /pattern/ is a regular expression all the same; /pattern/c is case-sensitive.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
    }
}

/// A short guide to regular expressions (ICU syntax, as NSRegularExpression uses).
private struct RegexReference: View {
    private static let rows: [(String, String)] = [
        (".", "any character"),
        ("\\d  \\w  \\s", "a digit, word character or whitespace (\\D \\W \\S: anything else)"),
        ("[abc]  [^abc]  [a-z]", "one of, none of, a range"),
        ("^  $  \\b", "start, end, word boundary"),
        ("a|b", "either"),
        ("(…)  (?:…)", "a group; one that doesn't capture"),
        ("*  +  ?  {2,5}", "repeat: any number, one or more, optional, 2 to 5 times (add ? for as few as possible)"),
        ("\\.  \\(  \\[", "a literal . ( or ["),
        ("(?-i)", "case-sensitive from here on"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Regular expressions").font(.headline)
            Text("Matches processes whose name, path, command line, title, user, app name, bundle ID or PID contains a match, ignoring case.")
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Self.rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text(row.1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
    }
}
