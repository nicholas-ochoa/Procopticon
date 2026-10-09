import AppKit
import ProcopticonCore
import UniformTypeIdentifiers

/// Saves a table as JSON or CSV (see `ExportFormatting`).
enum TableExport {
    enum Format: String, CaseIterable {
        case json = "JSON"
        case csv = "CSV"

        var contentType: UTType { self == .json ? .json : .commaSeparatedText }
        var fileExtension: String { self == .json ? "json" : "csv" }
    }

    static let formatKey = "exportFormat"

    /// The process list as shown: its visible columns, in their order, and its rows (filtered, in
    /// tree order or as sorted).
    @MainActor
    static func saveProcessList() {
        guard let table = ProcessSelection.shared.table.exportTable() else { return }
        save(table, name: "Processes", root: "processes")
    }

    @MainActor
    static func save(_ table: ExportTable, name: String, root: String) {
        let panel = NSSavePanel()
        let saved = Format(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .json
        let picker = FormatPicker(panel: panel, name: name, format: saved)
        panel.accessoryView = picker.view
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        picker.apply()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(picker.format.rawValue, forKey: formatKey)
        let text = picker.format == .json ? ExportFormatting.json(table, root: root) : ExportFormatting.csv(table)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Alerts.error("Unable to save", error.localizedDescription)
        }
    }

    /// The Format pop-up in the save panel; switching it changes the file's extension.
    @MainActor
    private final class FormatPicker: NSObject {
        let panel: NSSavePanel
        let name: String
        private(set) var format: Format
        let view: NSView
        private let popUp: NSPopUpButton

        init(panel: NSSavePanel, name: String, format: Format) {
            self.panel = panel
            self.name = name
            self.format = format
            popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.addItems(withTitles: Format.allCases.map(\.rawValue))
            popUp.selectItem(withTitle: format.rawValue)
            let label = NSTextField(labelWithString: "Format:")
            let stack = NSStackView(views: [label, popUp])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
            view = stack
            super.init()
            popUp.target = self
            popUp.action = #selector(changed(_:))
        }

        @objc private func changed(_ sender: NSPopUpButton) {
            format = Format(rawValue: sender.titleOfSelectedItem ?? "") ?? .json
            apply()
        }

        func apply() {
            panel.allowedContentTypes = [format.contentType]
            let current = panel.nameFieldStringValue
            let base = current.isEmpty ? name : (current as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        }
    }
}
