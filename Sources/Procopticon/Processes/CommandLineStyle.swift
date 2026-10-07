import AppKit
import ProcopticonCore

/// Colors for command lines and arguments: the executable dimmed and options in teal. Shared by the
/// process list, the Arguments tab and the process hover card.
enum CommandLineStyle {
    /// nil keeps the default text color.
    static func color(_ role: CommandLineSyntax.Role) -> NSColor? {
        switch role {
        case .executable: .secondaryLabelColor
        case .option: .systemTeal
        case .plain: nil
        }
    }

    /// Colors only; table cells supply the font.
    static func attributed(_ segments: [CommandLineSyntax.Segment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            let attributes: [NSAttributedString.Key: Any] = color(segment.role).map { [.foregroundColor: $0] } ?? [:]
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }

    static func commandLine(_ arguments: [String]) -> NSAttributedString {
        attributed(CommandLineSyntax.segments(commandLine: arguments))
    }
}
