import AppKit
import ProcopticonCore
import ProcopticonExpressions
import SwiftUI

/// Checks expressions and searches typed in Settings against the running processes.
@MainActor
enum ExpressionCheck {
    /// The main thread's engine; the process store and the alerts have their own.
    static let engine = ProcessExpressionEngine()

    struct Outcome: Equatable {
        var matches = 0
        /// Why it doesn't compile, or the first error it ran into.
        var error: String?
    }

    /// Search text as the process list uses it: plain text, a regular expression or "=expression".
    static func search(_ text: String, regex: Bool) -> Outcome {
        let matcher = ProcessMatcher(text, regex: regex, engine: engine)
        if let error = matcher.error {
            return Outcome(error: error)
        }
        return run(matcher.evaluate)
    }

    /// An expression on its own, as in a highlight rule or an alert condition.
    static func expression(_ text: String) -> Outcome {
        let source = ProcessExpressions.source(text)
        guard !source.isEmpty else { return Outcome() }
        let compiled = engine.compile(source)
        if let error = compiled.error {
            return Outcome(error: error)
        }
        return run(compiled.evaluate)
    }

    private static func run(_ evaluate: (ProcessItem) -> Result<Bool, ExpressionError>) -> Outcome {
        var outcome = Outcome()
        var errors = ExpressionErrors()
        for item in ProcessStore.shared.items.values where !item.isRemoved {
            switch evaluate(item) {
            case .success(let matches):
                if matches { outcome.matches += 1 }
            case .failure(let error):
                errors.record(error)
            }
        }
        outcome.error = errors.summary(rows: "processes")
        return outcome
    }

    static func summary(_ matches: Int) -> String {
        switch matches {
        case 0: return "Matches no running processes."
        case 1: return "Matches 1 running process."
        default: return "Matches \(Fmt.count(matches)) running processes."
        }
    }
}

/// What a search or expression matches among the running processes, or why it doesn't work.
struct ExpressionStatus: View {
    let outcome: ExpressionCheck.Outcome
    /// Shown when there's nothing to check.
    var placeholder: String?

    var body: some View {
        if let error = outcome.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .textSelection(.enabled)
        } else if let placeholder {
            Text(placeholder).font(.caption).foregroundStyle(.secondary)
        } else {
            Text(ExpressionCheck.summary(outcome.matches)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A field for a JavaScript expression over a process's values (see `ProcessExpressions`), with
/// what it matches among the running processes or why it doesn't work.
struct ProcessExpressionField: View {
    @Binding var text: String
    var prompt: String
    @State private var outcome = ExpressionCheck.Outcome()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Expression", text: $text, prompt: Text(prompt), axis: .vertical)
                .labelsHidden()
                .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                .lineLimit(1...4)
            ExpressionStatus(outcome: outcome,
                             placeholder: ProcessExpressions.source(text).isEmpty ? "Enter an expression, such as \(prompt)." : nil)
        }
        // Checked when the text changes rather than at every sample, so the form isn't rebuilt
        // each second while you type.
        .task(id: text) { outcome = ExpressionCheck.expression(text) }
    }
}

/// The round help button, showing the expression reference in a popover.
struct ExpressionReferenceButton: View {
    @State private var showing = false

    var body: some View {
        HelpLink { showing.toggle() }
            .controlSize(.small)
            .help("Show the values and examples expressions can use")
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                ExpressionReference().frame(width: 580, height: 540)
            }
    }
}

@MainActor
enum ExpressionReferenceWindow {
    static func open() {
        WindowManager.shared.show(id: "expression-reference", title: "Expression Reference",
                                  size: NSSize(width: 620, height: 640)) {
            ExpressionReference()
        }
    }
}

/// What expressions can use: the process's values, constants and examples.
struct ExpressionReference: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("""
                    An expression is JavaScript, evaluated for each process: the process matches when it's true. \
                    The process's values below are its variables. Type one in the process search field after \
                    “=”, as a custom highlight rule (Settings ▸ Highlighting), as an alert condition or to pick \
                    the processes an alert watches (Settings ▸ Alerts).
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                section("Examples") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(ProcessExpressions.examples, id: \.expression) { example in
                            GridRow {
                                Text("=" + example.expression).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Text(example.help).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                section("Values") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(ProcessExpressions.fields, id: \.name) { field in
                            GridRow {
                                Text(field.name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Text(field.kind.rawValue).foregroundStyle(.secondary)
                                Text(field.help).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach(ProcessExpressions.constants, id: \.name) { constant in
                            GridRow {
                                Text(constant.name).font(.system(.body, design: .monospaced))
                                Text("constant").foregroundStyle(.secondary)
                                Text(constant.help)
                            }
                        }
                    }
                }
                Text("""
                    Text that isn't known is empty; numbers and yes/no values that aren't known are null, which no \
                    comparison matches. Memory and data are in bytes, rates in bytes per second. Regular expressions \
                    work as usual: /safari/i.test(name). An expression that throws an error for a process doesn't \
                    match it; one that runs for more than a quarter of a second is stopped and not run again until \
                    you change it.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}
