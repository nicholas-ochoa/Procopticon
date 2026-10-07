import Foundation

/// Splits command lines and arguments into the parts they're colored by: the executable, options
/// and everything else.
public enum CommandLineSyntax {
    public enum Role: Sendable {
        case executable
        case option
        case plain
    }

    public struct Segment: Equatable, Sendable {
        public var text: String
        public var role: Role

        public init(_ text: String, _ role: Role) {
            self.text = text
            self.role = role
        }
    }

    /// A shell-quoted command line, with a plain space between arguments.
    public static func segments(commandLine arguments: [String]) -> [Segment] {
        var result: [Segment] = []
        for (index, argument) in arguments.enumerated() {
            if index > 0 {
                result.append(Segment(" ", .plain))
            }
            result += segments(argument: argument, index: index, text: argument.shellQuoted)
        }
        return result
    }

    /// One argument at `index` in argv, shown as `text` (the argument itself by default). An
    /// option's value after "=" is left plain.
    public static func segments(argument: String, index: Int, text: String? = nil) -> [Segment] {
        let text = text ?? argument
        if index == 0 {
            return [Segment(text, .executable)]
        }
        guard isOption(argument) else {
            return [Segment(text, .plain)]
        }
        guard let equals = text.firstIndex(of: "=") else {
            return [Segment(text, .option)]
        }
        return [Segment(String(text[..<equals]), .option), Segment(String(text[equals...]), .plain)]
    }

    /// "-v", "--name" or "--name=value", but not "-" (standard input) or a negative number.
    static func isOption(_ argument: String) -> Bool {
        argument.hasPrefix("-") && argument.count > 1 && Double(argument) == nil
    }
}
