import AppKit

/// The About panel: the standard one, with a link to the licenses of Procopticon and of what it includes.
@MainActor
enum AboutPanel {
    static let repository = "https://github.com/nicholas-ochoa/Procopticon"

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © 2026 Nicholas Ochoa. MIT License.",
        ])
        NSApp.activate()
    }

    /// A line about the app and its licenses. The license texts themselves are files in the
    /// bundle's Resources/Licenses (scripts/build-app.sh copies them there), which the last link
    /// opens; a bare executable (`swift run`) has none, and the link goes to the repository.
    private static var credits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let text = NSMutableAttributedString()
        func add(_ string: String, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]
            if let link { attributes[.link] = link }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        add("Every process, in plain sight.\n")
        add(repository, link: URL(string: repository))
        add("\n\nReleased under the MIT License.\nIncludes QuickJS-ng (MIT License).\n")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true)
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            add("Show License Texts", link: bundled)
        } else {
            add("License Texts", link: URL(string: repository + "/blob/main/THIRD_PARTY_NOTICES.md"))
        }
        return text
    }
}
