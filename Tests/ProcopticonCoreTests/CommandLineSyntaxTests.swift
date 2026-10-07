import XCTest
@testable import ProcopticonCore

final class CommandLineSyntaxTests: XCTestCase {
    func testCommandLineSegments() {
        let segments = CommandLineSyntax.segments(commandLine: ["/bin/ls", "-la", "--color=auto", "-1", "-", "my file"])
        XCTAssertEqual(segments, [
            .init("/bin/ls", .executable), .init(" ", .plain),
            .init("-la", .option), .init(" ", .plain),
            .init("--color", .option), .init("=auto", .plain), .init(" ", .plain),
            .init("-1", .plain), .init(" ", .plain),
            .init("-", .plain), .init(" ", .plain),
            .init("'my file'", .plain),
        ])
    }

    func testArgumentSegments() {
        XCTAssertEqual(CommandLineSyntax.segments(argument: "-tool", index: 0), [.init("-tool", .executable)])
        XCTAssertEqual(CommandLineSyntax.segments(argument: "--name=a b", index: 2), [.init("--name", .option), .init("=a b", .plain)])
        XCTAssertEqual(CommandLineSyntax.segments(argument: "value=1", index: 1), [.init("value=1", .plain)])
    }
}
