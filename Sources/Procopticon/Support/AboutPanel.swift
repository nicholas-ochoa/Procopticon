import AppKit

/// The About panel: the standard one, with the licenses of Procopticon and of what it includes.
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

    /// The license texts, from the bundle's Resources/Licenses (scripts/build-app.sh copies them
    /// there). A bare executable (`swift run`) has none and says where they are instead.
    private static var credits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let heading = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let text = NSMutableAttributedString()
        func add(_ string: String, font: NSFont = body, link: String? = nil, style: NSParagraphStyle? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link, let url = URL(string: link) { attributes[.link] = url }
            if let style { attributes[.paragraphStyle] = style }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        add("A process explorer for macOS.\n", style: centered)
        add(repository, link: repository, style: centered)
        add("\n\n", style: centered)

        let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses")
        let sections = [("Procopticon", "Procopticon.txt"), ("QuickJS-ng (JavaScript expressions)", "QuickJS-ng.txt")]
        var found = false
        for (title, file) in sections {
            guard let url = licenses?.appendingPathComponent(file), let license = try? String(contentsOf: url, encoding: .utf8) else { continue }
            found = true
            add("\(title)\n", font: heading)
            add(license.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n")
        }
        if !found {
            add("Procopticon is released under the MIT License. It includes QuickJS-ng (MIT License). "
                + "The license texts are in LICENSE and THIRD_PARTY_NOTICES.md at ")
            add("the repository", link: repository)
            add(".")
        }
        return text
    }
}
