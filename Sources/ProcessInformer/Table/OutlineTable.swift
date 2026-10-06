import AppKit
import InformerCore
import SwiftUI

/// Describes one column of an `OutlineTable`.
struct TableColumnSpec<Item> {
    enum Kind {
        case text
        case graph
    }

    let id: String
    let title: String
    var width: CGFloat = 100
    var alignment: NSTextAlignment = .left
    var defaultVisible = true
    var monospacedDigits = true
    var kind: Kind = .text
    var text: (Item) -> String
    /// Ascending comparator; nil disables sorting by this column.
    var less: ((Item, Item) -> Bool)?
    var image: ((Item) -> NSImage?)?
    var tooltip: ((Item) -> String?)?
    var graph: ((Item) -> GraphCellData?)?
    var help: String?

    init(_ id: String, _ title: String, width: CGFloat = 100, align: NSTextAlignment = .left, visible: Bool = true,
         help: String? = nil, text: @escaping (Item) -> String, less: ((Item, Item) -> Bool)? = nil) {
        self.id = id
        self.title = title
        self.width = width
        alignment = align
        defaultVisible = visible
        self.help = help
        self.text = text
        self.less = less
    }

    /// Convenience: numeric column sorted by a numeric key.
    static func number<V: Comparable>(_ id: String, _ title: String, width: CGFloat = 80, visible: Bool = true, help: String? = nil,
                                     value: @escaping (Item) -> V, text: @escaping (Item) -> String) -> TableColumnSpec {
        TableColumnSpec(id, title, width: width, align: .right, visible: visible, help: help, text: text, less: { value($0) < value($1) })
    }

    /// Convenience: string column sorted case-insensitively.
    static func string(_ id: String, _ title: String, width: CGFloat = 120, visible: Bool = true, help: String? = nil,
                       text: @escaping (Item) -> String) -> TableColumnSpec {
        TableColumnSpec(id, title, width: width, visible: visible, help: help, text: text, less: {
            text($0).localizedStandardCompare(text($1)) == .orderedAscending
        })
    }
}

struct GraphCellData {
    var values: [Double]
    var maxValue: Double
    var color: NSColor
    var secondary: [Double]?
    var secondaryColor: NSColor?
}

struct RowStyle: Equatable {
    var background: NSColor?
    var textColor: NSColor?
}

/// SwiftUI wrapper around a view-based NSOutlineView suitable for large, frequently updated lists.
struct OutlineTable<Item>: NSViewRepresentable {
    var roots: [Item]
    var children: ((Item) -> [Item])?
    var revision: Int
    var columns: [TableColumnSpec<Item>]
    var autosaveName: String
    var key: (Item) -> AnyHashable
    var rowStyle: ((Item) -> RowStyle?)?
    var menu: (([Item]) -> NSMenu?)?
    var onDoubleClick: ((Item) -> Void)?
    var onSelectionChange: (([Item]) -> Void)?
    var onDeleteKey: (([Item]) -> Void)?
    var defaultSort: (column: String, ascending: Bool)?
    var expandByDefault = true
    var rowHeight: CGFloat = 20
    var controller: OutlineTableController?

    func makeCoordinator() -> OutlineTableCoordinator<Item> {
        OutlineTableCoordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let outline = KeyOutlineView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.allowsColumnSelection = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.rowHeight = rowHeight
        outline.intercellSpacing = NSSize(width: 6, height: 1)
        outline.style = .fullWidth
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.gridStyleMask = []
        outline.headerView = NSTableHeaderView()

        let coordinator = context.coordinator
        coordinator.outline = outline
        coordinator.installColumns()
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(OutlineTableCoordinator<Item>.doubleClicked(_:))
        outline.menu = NSMenu()
        outline.menu?.delegate = coordinator
        outline.headerView?.menu = coordinator.headerMenu()
        outline.keyHandler = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }
        outline.copyHandler = { [weak coordinator] in coordinator?.copySelection() }
        scroll.documentView = outline
        coordinator.reload(force: true)
        coordinator.bindController()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previousRevision = coordinator.parent.revision
        coordinator.parent = self
        if previousRevision != revision {
            coordinator.reload(force: false)
        }
        coordinator.bindController()
    }
}

/// Handle for imperatively driving a table from outside SwiftUI (export, reveal).
final class OutlineTableController {
    fileprivate var exportHandler: (() -> String)?
    fileprivate var revealHandler: ((AnyHashable) -> Bool)?
    fileprivate var focusHandler: (() -> Void)?

    func exportText() -> String { exportHandler?() ?? "" }

    @discardableResult
    func reveal(_ key: AnyHashable) -> Bool { revealHandler?(key) ?? false }

    func focus() { focusHandler?() }
}

final class OutlineNode<Item>: NSObject {
    let key: AnyHashable
    var value: Item
    var children: [OutlineNode<Item>] = []
    weak var parentNode: OutlineNode<Item>?

    init(key: AnyHashable, value: Item) {
        self.key = key
        self.value = value
    }
}

final class OutlineTableCoordinator<Item>: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var parent: OutlineTable<Item>
    weak var outline: KeyOutlineView?
    private var nodes: [AnyHashable: OutlineNode<Item>] = [:]
    private var rootNodes: [OutlineNode<Item>] = []
    private var flatKeys: [AnyHashable] = []
    private var collapsed = Set<AnyHashable>()
    private var knownKeys = Set<AnyHashable>()
    private var sortColumn: String?
    private var sortAscending = true
    private var suppressSelectionCallback = false
    private var columnMap: [String: TableColumnSpec<Item>] = [:]

    init(_ parent: OutlineTable<Item>) {
        self.parent = parent
        super.init()
        for c in parent.columns {
            columnMap[c.id] = c
        }
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "\(parent.autosaveName).sortColumn") {
            sortColumn = saved.isEmpty ? nil : saved
            sortAscending = defaults.bool(forKey: "\(parent.autosaveName).sortAscending")
        } else if let d = parent.defaultSort {
            sortColumn = d.column
            sortAscending = d.ascending
        }
    }

    func bindController() {
        guard let controller = parent.controller else { return }
        controller.exportHandler = { [weak self] in self?.exportText() ?? "" }
        controller.revealHandler = { [weak self] key in self?.reveal(key) ?? false }
        controller.focusHandler = { [weak self] in
            guard let outline = self?.outline else { return }
            outline.window?.makeFirstResponder(outline)
        }
    }

    func reveal(_ key: AnyHashable) -> Bool {
        guard let outline, let node = nodes[key] else { return false }
        var chain: [OutlineNode<Item>] = []
        var p = node.parentNode
        while let n = p {
            chain.insert(n, at: 0)
            p = n.parentNode
        }
        for n in chain {
            outline.expandItem(n)
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        outline.window?.makeFirstResponder(outline)
        return true
    }

    // MARK: Columns

    private var hiddenKey: String { "\(parent.autosaveName).hiddenColumns" }
    private var shownKey: String { "\(parent.autosaveName).shownColumns" }

    func installColumns() {
        guard let outline else { return }
        let defaults = UserDefaults.standard
        let hidden = Set(defaults.stringArray(forKey: hiddenKey) ?? [])
        let shown = Set(defaults.stringArray(forKey: shownKey) ?? [])
        for spec in parent.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 24
            column.maxWidth = 4000
            column.headerToolTip = spec.help ?? spec.title
            column.headerCell.alignment = spec.alignment
            if spec.less != nil {
                column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: spec.alignment != .right)
            }
            column.isHidden = hidden.contains(spec.id) || (!spec.defaultVisible && !shown.contains(spec.id))
            column.resizingMask = .userResizingMask
            outline.addTableColumn(column)
        }
        if let first = outline.tableColumns.first, parent.children != nil {
            outline.outlineTableColumn = first
        } else {
            outline.outlineTableColumn = nil
        }
        outline.autosaveName = parent.autosaveName
        outline.autosaveTableColumns = true
        // Autosave may restore column order; re-apply hidden state after it.
        for column in outline.tableColumns {
            let id = column.identifier.rawValue
            if let spec = columnMap[id] {
                column.isHidden = hidden.contains(id) || (!spec.defaultVisible && !shown.contains(id))
            }
        }
        if parent.children != nil, let first = outline.tableColumns.first(where: { $0.identifier.rawValue == parent.columns.first?.id }) {
            outline.outlineTableColumn = first
        }
        if let sortColumn {
            outline.sortDescriptors = [NSSortDescriptor(key: sortColumn, ascending: sortAscending)]
        }
    }

    func headerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.identifier = NSUserInterfaceItemIdentifier("header")
        return menu
    }

    private func populateHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outline else { return }
        menu.addItem(ClosureMenuItem(title: "Reset Sort Order") { [weak self] in
            self?.sortColumn = nil
            self?.outline?.sortDescriptors = []
            self?.saveSort()
            self?.reload(force: true)
        })
        menu.addItem(ClosureMenuItem(title: "Size Columns to Fit") { [weak self] in
            self?.sizeColumnsToFit()
        })
        menu.addItem(.separator())
        let sorted = parent.columns.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        for spec in sorted {
            guard let column = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(spec.id)) else { continue }
            let item = ClosureMenuItem(title: spec.title) { [weak self, weak column] in
                guard let self, let column else { return }
                column.isHidden.toggle()
                self.saveColumnVisibility()
            }
            item.state = column.isHidden ? .off : .on
            item.toolTip = spec.help
            if column == outline.outlineTableColumn {
                item.isEnabled = false
                item.action = nil
            }
            menu.addItem(item)
        }
    }

    private func saveColumnVisibility() {
        guard let outline else { return }
        var hidden: [String] = []
        var shown: [String] = []
        for column in outline.tableColumns {
            let id = column.identifier.rawValue
            guard let spec = columnMap[id] else { continue }
            if column.isHidden, spec.defaultVisible { hidden.append(id) }
            if !column.isHidden, !spec.defaultVisible { shown.append(id) }
        }
        UserDefaults.standard.set(hidden, forKey: hiddenKey)
        UserDefaults.standard.set(shown, forKey: shownKey)
        outline.reloadData()
        restoreExpansion()
    }

    private func sizeColumnsToFit() {
        guard let outline else { return }
        let rows = min(outline.numberOfRows, 400)
        for (index, column) in outline.tableColumns.enumerated() where !column.isHidden {
            var width = (column.headerCell.cellSize.width) + 12
            for row in 0..<rows {
                if let view = outline.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView,
                   let field = view.textField {
                    var w = field.intrinsicContentSize.width + 8
                    if view.imageView?.image != nil { w += 22 }
                    if column == outline.outlineTableColumn {
                        w += CGFloat(outline.level(forRow: row) + 1) * outline.indentationPerLevel + 16
                    }
                    width = max(width, w)
                }
            }
            column.width = min(width, 600)
        }
    }

    private func saveSort() {
        UserDefaults.standard.set(sortColumn ?? "", forKey: "\(parent.autosaveName).sortColumn")
        UserDefaults.standard.set(sortAscending, forKey: "\(parent.autosaveName).sortAscending")
    }

    // MARK: Data

    private func comparator() -> ((OutlineNode<Item>, OutlineNode<Item>) -> Bool)? {
        guard let sortColumn, let spec = columnMap[sortColumn], let less = spec.less else { return nil }
        let asc = sortAscending
        return { a, b in
            if asc {
                return less(a.value, b.value)
            }
            return less(b.value, a.value)
        }
    }

    func reload(force: Bool) {
        guard let outline else { return }
        var newNodes: [AnyHashable: OutlineNode<Item>] = [:]
        newNodes.reserveCapacity(nodes.count)
        let compare = comparator()
        let childrenFn = parent.children
        let keyFn = parent.key

        func build(_ items: [Item], parentNode: OutlineNode<Item>?) -> [OutlineNode<Item>] {
            var result: [OutlineNode<Item>] = []
            result.reserveCapacity(items.count)
            for item in items {
                let k = keyFn(item)
                let node: OutlineNode<Item>
                if let existing = nodes[k] {
                    node = existing
                    node.value = item
                } else {
                    node = OutlineNode(key: k, value: item)
                }
                node.parentNode = parentNode
                newNodes[k] = node
                if let childrenFn {
                    node.children = build(childrenFn(item), parentNode: node)
                }
                result.append(node)
            }
            if let compare {
                result.sort(by: compare)
            }
            return result
        }
        rootNodes = build(parent.roots, parentNode: nil)
        nodes = newNodes

        var flat: [AnyHashable] = []
        flat.reserveCapacity(nodes.count)
        func flatten(_ list: [OutlineNode<Item>]) {
            for n in list {
                flat.append(n.key)
                flatten(n.children)
            }
        }
        flatten(rootNodes)

        if force || flat != flatKeys {
            let selectedKeys = selectedNodes().map(\.key)
            suppressSelectionCallback = true
            outline.reloadData()
            restoreExpansion()
            let rows = IndexSet(selectedKeys.compactMap { k -> Int? in
                guard let n = nodes[k] else { return nil }
                let r = outline.row(forItem: n)
                return r >= 0 ? r : nil
            })
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            suppressSelectionCallback = false
            if rows.count != selectedKeys.count {
                notifySelection()
            }
        } else {
            refreshVisibleRows()
        }
        flatKeys = flat
        for k in flat { knownKeys.insert(k) }
    }

    private func restoreExpansion() {
        guard let outline, parent.children != nil else { return }
        func expand(_ list: [OutlineNode<Item>]) {
            for n in list where !n.children.isEmpty {
                let shouldExpand = parent.expandByDefault ? !collapsed.contains(n.key) : expandedExplicitly.contains(n.key)
                if shouldExpand {
                    outline.expandItem(n)
                    expand(n.children)
                }
            }
        }
        expand(rootNodes)
    }

    private var expandedExplicitly = Set<AnyHashable>()

    private func refreshVisibleRows() {
        guard let outline else { return }
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<min(outline.numberOfRows, visible.location + visible.length) {
            guard let node = outline.item(atRow: row) as? OutlineNode<Item> else { continue }
            for (index, column) in outline.tableColumns.enumerated() where !column.isHidden {
                guard let view = outline.view(atColumn: index, row: row, makeIfNecessary: false) else { continue }
                configure(view, column: column, node: node)
            }
            if let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? ColoredRowView {
                applyStyle(rowView, node: node)
            }
        }
    }

    func selectedNodes() -> [OutlineNode<Item>] {
        guard let outline else { return [] }
        return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? OutlineNode<Item> }
    }

    func selectedItems() -> [Item] {
        selectedNodes().map(\.value)
    }

    private func notifySelection() {
        parent.onSelectionChange?(selectedItems())
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? OutlineNode<Item> {
            return node.children.count
        }
        return rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? OutlineNode<Item> {
            return node.children[index]
        }
        return rootNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? OutlineNode<Item> else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = outlineView.sortDescriptors.first, let key = d.key else { return }
        sortColumn = key
        sortAscending = d.ascending
        saveSort()
        reload(force: true)
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn, let node = item as? OutlineNode<Item>, let spec = columnMap[tableColumn.identifier.rawValue] else {
            return nil
        }
        let view: NSView
        switch spec.kind {
        case .graph:
            let id = NSUserInterfaceItemIdentifier("graph")
            view = outlineView.makeView(withIdentifier: id, owner: nil) ?? {
                let v = SparklineCellView()
                v.identifier = id
                return v
            }()
        case .text:
            let withImage = spec.image != nil
            let id = NSUserInterfaceItemIdentifier(withImage ? "textImage" : "text")
            view = outlineView.makeView(withIdentifier: id, owner: nil) ?? TextCellView.make(identifier: id, withImage: withImage)
        }
        configure(view, column: tableColumn, node: node)
        return view
    }

    private func configure(_ view: NSView, column: NSTableColumn, node: OutlineNode<Item>) {
        guard let spec = columnMap[column.identifier.rawValue] else { return }
        if let graphView = view as? SparklineCellView {
            graphView.data = spec.graph?(node.value)
            graphView.needsDisplay = true
            return
        }
        guard let cell = view as? TextCellView else { return }
        let text = spec.text(node.value)
        if cell.textField?.stringValue != text {
            cell.textField?.stringValue = text
        }
        cell.textField?.alignment = spec.alignment
        if let imageFn = spec.image {
            cell.imageView?.image = imageFn(node.value)
        }
        let style = parent.rowStyle?(node.value)
        cell.textField?.textColor = style?.textColor ?? .labelColor
        cell.toolTip = spec.tooltip?(node.value)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = ColoredRowView()
        if let node = item as? OutlineNode<Item> {
            applyStyle(row, node: node)
        }
        return row
    }

    private func applyStyle(_ row: ColoredRowView, node: OutlineNode<Item>) {
        let color = parent.rowStyle?(node.value)?.background
        if row.highlightColor != color {
            row.highlightColor = color
            row.needsDisplay = true
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !suppressSelectionCallback {
            notifySelection()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? OutlineNode<Item> {
            collapsed.insert(node.key)
            expandedExplicitly.remove(node.key)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? OutlineNode<Item> {
            collapsed.remove(node.key)
            expandedExplicitly.insert(node.key)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let node = item as? OutlineNode<Item>, let first = parent.columns.first else { return nil }
        return first.text(node.value)
    }

    func outlineView(_ outlineView: NSOutlineView, didResize tableColumn: NSTableColumn) {}

    @objc func doubleClicked(_ sender: Any?) {
        guard let outline, outline.clickedRow >= 0,
              let node = outline.item(atRow: outline.clickedRow) as? OutlineNode<Item> else { return }
        parent.onDoubleClick?(node.value)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier?.rawValue == "header" {
            populateHeaderMenu(menu)
            return
        }
        menu.removeAllItems()
        guard let outline else { return }
        // Right-clicking a row outside the selection selects it first (Finder behavior).
        let clicked = outline.clickedRow
        if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
            outline.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let items = selectedItems()
        guard !items.isEmpty, let built = parent.menu?(items) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: "Copy", key: "") { [weak self] in self?.copySelection() })
        if let clickedColumn = clickedColumnSpec() {
            menu.addItem(ClosureMenuItem(title: "Copy \"\(clickedColumn.title)\"") { [weak self] in
                guard let self else { return }
                let text = self.selectedItems().map { clickedColumn.text($0) }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
        }
    }

    private func clickedColumnSpec() -> TableColumnSpec<Item>? {
        guard let outline, outline.clickedColumn >= 0 else { return nil }
        let column = outline.tableColumns[outline.clickedColumn]
        return columnMap[column.identifier.rawValue]
    }

    func copySelection() {
        guard let outline else { return }
        let visible = outline.tableColumns.filter { !$0.isHidden }.compactMap { columnMap[$0.identifier.rawValue] }
            .filter { $0.kind == .text }
        let lines = selectedItems().map { item in visible.map { $0.text(item) }.joined(separator: "\t") }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// All rows (in display order) as tab separated text, for export.
    func exportText() -> String {
        guard let outline else { return "" }
        let visible = outline.tableColumns.filter { !$0.isHidden }.compactMap { columnMap[$0.identifier.rawValue] }
            .filter { $0.kind == .text }
        var lines = [visible.map(\.title).joined(separator: "\t")]
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? OutlineNode<Item> else { continue }
            let indent = String(repeating: "  ", count: outline.level(forRow: row))
            lines.append(visible.enumerated().map { $0.offset == 0 ? indent + $0.element.text(node.value) : $0.element.text(node.value) }
                .joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: // return, enter
            if let first = selectedItems().first {
                parent.onDoubleClick?(first)
                return true
            }
        case 51, 117: // delete, forward delete
            let items = selectedItems()
            if !items.isEmpty, let handler = parent.onDeleteKey {
                handler(items)
                return true
            }
        default:
            break
        }
        return false
    }
}

final class KeyOutlineView: NSOutlineView {
    var keyHandler: ((NSEvent) -> Bool)?
    var copyHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        copyHandler?()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return selectedRow >= 0
        }
        return super.validateUserInterfaceItem(item)
    }
}

final class ColoredRowView: NSTableRowView {
    var highlightColor: NSColor?

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if let highlightColor {
            highlightColor.setFill()
            bounds.fill()
        }
    }
}

final class TextCellView: NSTableCellView {
    static func make(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> TextCellView {
        let cell = TextCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            ])
        } else {
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Tiny history graph drawn inside a table cell.
final class SparklineCellView: NSView {
    var data: GraphCellData?

    override func draw(_ dirtyRect: NSRect) {
        guard let data, !data.values.isEmpty else { return }
        let rect = bounds.insetBy(dx: 1, dy: 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
        rect.fill()
        func path(_ values: [Double], _ color: NSColor) {
            let maxV = max(data.maxValue, 0.0001)
            let count = values.count
            let step = rect.width / CGFloat(max(1, min(count, Int(rect.width)) - 1))
            let slice = values.suffix(Int(rect.width))
            let p = NSBezierPath()
            p.move(to: NSPoint(x: rect.minX, y: rect.minY))
            for (i, v) in slice.enumerated() {
                let x = rect.minX + CGFloat(i) * step
                let y = rect.minY + CGFloat(min(1, v / maxV)) * rect.height
                p.line(to: NSPoint(x: x, y: y))
            }
            p.line(to: NSPoint(x: rect.minX + CGFloat(max(0, slice.count - 1)) * step, y: rect.minY))
            p.close()
            color.withAlphaComponent(0.35).setFill()
            p.fill()
            color.setStroke()
            p.lineWidth = 1
            p.stroke()
        }
        path(data.values, data.color)
        if let s = data.secondary, let c = data.secondaryColor {
            path(s, c)
        }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        if !enabled {
            action = nil
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, enabled: Bool = true, state: NSControl.StateValue = .off, image: String? = nil, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, enabled: enabled, handler: handler)
        item.state = state
        if let image {
            item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        }
        addItem(item)
        return item
    }

    @discardableResult
    func submenu(_ title: String, image: String? = nil, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        build(sub)
        item.submenu = sub
        if let image {
            item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        }
        addItem(item)
        return item
    }
}
