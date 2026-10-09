import AppKit
import ProcopticonCore
import SwiftUI

/// Hover card for the process list's Name column: what the process is, where it was started from
/// and anything unusual about it.
struct ProcessToolTipView: View {
    let item: ProcessItem
    private let signing: SigningInfo?
    private let responsible: ProcessItem?

    init(item: ProcessItem, store: ProcessStore = .shared) {
        self.item = item
        signing = item.signing
        responsible = item.record.responsiblePid.flatMap { $0 == item.pid ? nil : store.item(pid: $0) }
    }

    private var record: ProcessRecord { item.record }
    private static let mono = Font.system(size: 11, design: .monospaced)

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            header
                .padding(.bottom, 2)
            Divider()
                .gridCellUnsizedAxes(.horizontal)
            if let path = record.path, !path.isEmpty {
                row("Path", Text(Self.pathText(path)))
            }
            if let arguments = shownArguments {
                row("Command", Text(Self.commandText(arguments)).lineLimit(10))
            }
            if let title = record.title {
                row("Title", Text(title).font(Self.mono))
            }
            if let signing, signing.status != .unknown {
                row("Signer", signerText(signing))
            }
            if let q = item.bundleInfo?.quarantine {
                row("Source", Text(q.url.map { "\(q.sourceDescription)\n\($0)" } ?? q.sourceDescription).lineLimit(3))
            }
            row("User", userText)
            if record.startMicros > 0 {
                row("Started", startedText)
            }
            if let responsible {
                row("Responsible", Text("\(responsible.displayName)  \(Text(String(responsible.pid)).font(Self.mono).foregroundStyle(.secondary))"))
            }
            if !badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(badges, id: \.text) { $0 }
                }
                .padding(.top, 3)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: ProcessIcons.icon(for: record))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Text(item.displayName).font(.system(size: 13, weight: .semibold)))  \(Text(String(item.pid)).font(Self.mono).foregroundStyle(.secondary))")
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
                if let id = item.bundleInfo?.bundleIdentifier {
                    Text(id).font(Self.mono).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The bundle's name and version, e.g. "Sublime Text  Build 4214 (4214)".
    private var subtitle: String? {
        guard let b = item.bundleInfo else { return nil }
        let name = b.displayName.flatMap { $0 == item.displayName ? nil : $0 }
        let parts = [name, b.versionString.isEmpty ? nil : b.versionString].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    // MARK: Rows

    private func row(_ label: String, _ value: some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value
        }
    }

    /// The command line, unless it's only the executable already shown as the path.
    private var shownArguments: [String]? {
        guard let arguments = record.commandLineArguments else { return nil }
        if arguments.count == 1, let path = record.path,
           arguments[0] == path || arguments[0] == (path as NSString).lastPathComponent {
            return nil
        }
        return arguments
    }

    /// The directory dimmed, so the file name stands out.
    static func pathText(_ path: String) -> AttributedString {
        let name = (path as NSString).lastPathComponent
        var directory = AttributedString(path.dropLast(name.count))
        directory.font = mono
        directory.foregroundColor = .secondary
        var file = AttributedString(name)
        file.font = .system(size: 11, weight: .semibold, design: .monospaced)
        return directory + file
    }

    /// Shell-quoted arguments in the command line colors.
    static func commandText(_ arguments: [String]) -> AttributedString {
        var text = AttributedString()
        for segment in CommandLineSyntax.segments(commandLine: arguments) {
            // Word joiners keep lines from breaking at an option's hyphens.
            var part = AttributedString(segment.role == .option ? segment.text.replacingOccurrences(of: "-", with: "-\u{2060}") : segment.text)
            if let color = CommandLineStyle.color(segment.role) {
                part.foregroundColor = Color(nsColor: color)
            }
            text += part
        }
        text.font = mono
        return text
    }

    private func signerText(_ s: SigningInfo) -> Text {
        let (symbol, color): (String, Color) = switch s.status {
        case .valid: ("checkmark.seal.fill", .green)
        case .adhoc: ("seal", .orange)
        case .unsigned: ("xmark.seal", .red)
        case .invalid: ("xmark.seal.fill", .red)
        case .unknown: ("questionmark", .secondary)
        }
        let name = switch s.status {
        case .unsigned: "Unsigned"
        case .invalid: s.verificationSummary
        default: s.signer.isEmpty ? s.status.rawValue : s.signer
        }
        let seal = Text(Image(systemName: symbol)).foregroundStyle(color)
        if s.status == .valid, s.isNotarized, !s.isPlatformBinary {
            return Text("\(seal) \(name)  \(Text("notarized").foregroundStyle(.secondary))")
        }
        return Text("\(seal) \(name)")
    }

    private var userText: Text {
        let name = item.userName.isEmpty ? "\(record.uid)" : item.userName
        guard record.ruid != record.uid else { return Text(name) }
        return Text("\(name)  \(Text("real user \(UserNames.name(record.ruid))").foregroundStyle(.secondary))")
    }

    private var startedText: Text {
        let ago = Fmt.relative(seconds: Date().timeIntervalSince1970 - record.startTime)
        return Text("\(Fmt.date(record.startTime))  \(Text("\(ago) ago").foregroundStyle(.secondary))")
    }

    // MARK: Badges

    /// States worth calling out, in the colors of the matching row highlights.
    private var badges: [Badge] {
        var badges: [Badge] = []
        func add(_ text: String, _ symbol: String, _ rule: HighlightRule) {
            let color = AppSettings.shared.highlights[rule]?.color ?? rule.defaultColor
            badges.append(Badge(text: text, symbol: symbol, color: Color(nsColor: color)))
        }
        if item.isRemoved { add("Exited", "xmark.circle", .removed) }
        if item.isNotResponding { add("Not responding", "hourglass", .notResponding) }
        if record.isStopped { add("Stopped", "pause.circle", .suspended) }
        if record.isZombie { add("Zombie", "moon.zzz", .zombie) }
        if record.isTraced { add("Being traced", "ant", .debugged) }
        if record.isTranslated { add("Rosetta", "cpu", .translated) }
        if record.isElevated { add("Elevated (root)", "bolt.shield", .elevated) }
        if record.sandboxed == true { add("Sandboxed", "shield.lefthalf.filled", .sandboxed) }
        return badges
    }
}

private struct Badge: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
    }
}
