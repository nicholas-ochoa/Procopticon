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
    /// Font for text cells; nil uses the standard list font.
    var font: NSFont?
    /// Inactive tables (e.g. a hidden tab) are hidden and defer updates until shown again, so
    /// switching tabs never rebuilds a table from scratch.
    var isActive = true

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
        coordinator.iconObserver = NotificationCenter.default.addObserver(
            forName: ProcessIcons.didLoadNotification, object: nil, queue: .main) { [weak coordinator] _ in
            coordinator?.refreshVisibleRows()
        }
        scroll.documentView = outline
        scroll.isHidden = !isActive
        coordinator.applyFont()
        coordinator.reload(force: true)
        coordinator.bindController()
        return scroll
    }

    /// The table always fills the space it is offered. Answering directly keeps SwiftUI from
    /// measuring the scroll view's fitting size through Auto Layout, which walks every visible
    /// row and cell and was the largest main-thread cost during refreshes.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previousRevision = coordinator.parent.revision
        coordinator.parent = self
        if nsView.isHidden == isActive {
            nsView.isHidden = !isActive
        }
        coordinator.applyFont()
        let changed = previousRevision != revision
        if !isActive {
            // Populate once even while hidden (so the first switch is instant); defer the rest.
            if changed {
                if coordinator.hasLoaded {
                    coordinator.pendingReload = true
                } else {
                    coordinator.reload(force: false)
                }
            }
            return
        }
        if changed || coordinator.pendingReload {
            coordinator.pendingReload = false
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
    /// For flat lists a node is a reusable row slot, so its key can change.
    var key: AnyHashable
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
    private var sortColumn: String?
    private var sortAscending = true
    private var suppressSelectionCallback = false
    var iconObserver: NSObjectProtocol?

    deinit {
        if let iconObserver {
            NotificationCenter.default.removeObserver(iconObserver)
        }
    }
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

    private var appliedFont: NSFont?

    /// Applies a font change: adjusts row height and restyles existing cells.
    func applyFont() {
        guard let outline else { return }
        let font = parent.font ?? TextCellView.defaultFont
        guard font != appliedFont else { return }
        appliedFont = font
        let line = ceil(font.ascender - font.descender + font.leading)
        outline.rowHeight = max(parent.rowHeight, line + 5)
        outline.enumerateAvailableRowViews { rowView, _ in
            for i in 0..<rowView.numberOfColumns {
                (rowView.view(atColumn: i) as? TextCellView)?.setFont(font)
            }
        }
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
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

    private func comparator() -> ((Item, Item) -> Bool)? {
        guard let sortColumn, let spec = columnMap[sortColumn], let less = spec.less else { return nil }
        let asc = sortAscending
        return { a, b in asc ? less(a, b) : less(b, a) }
    }

    /// Result of the background preparation pass: ordering only, no AppKit objects.
    private struct Prepared {
        var rootKeys: [AnyHashable] = []
        var childKeys: [AnyHashable: [AnyHashable]] = [:]
        var values: [AnyHashable: Item] = [:]
        var flat: [AnyHashable] = []
    }

    private static var prepareQueue: DispatchQueue {
        DispatchQueue.global(qos: .userInitiated)
    }

    private var prepareGeneration = 0
    /// Set when an update arrived while the table was inactive.
    var pendingReload = false
    /// True once rows have been applied at least once.
    private(set) var hasLoaded = false

    /// Rebuilds the rows. Sorting and tree flattening (the expensive part, which also calls the
    /// column closures) run on a background queue; the main thread only reconciles nodes by key.
    func reload(force: Bool) {
        prepareGeneration &+= 1
        let gen = prepareGeneration
        let roots = parent.roots
        let childrenFn = parent.children
        let keyFn = parent.key
        let compare = comparator()
        let work = {
            Self.prepare(roots: roots, children: childrenFn, key: keyFn, compare: compare)
        }
        // Tiny lists aren't worth a thread hop (and avoid an empty first frame).
        if roots.count < 64 && childrenFn == nil {
            apply(work(), force: force)
            return
        }
        Self.prepareQueue.async { [weak self] in
            let prepared = work()
            DispatchQueue.main.async {
                guard let self, gen == self.prepareGeneration else { return }
                self.apply(prepared, force: force)
            }
        }
    }

    private static func prepare(roots: [Item], children: ((Item) -> [Item])?, key: (Item) -> AnyHashable,
                                compare: ((Item, Item) -> Bool)?) -> Prepared {
        var p = Prepared()
        p.values.reserveCapacity(roots.count)
        func level(_ items: [Item]) -> [AnyHashable] {
            // Stable sort: ties keep the provider's order, so equal rows (e.g. many processes at
            // 0% CPU) don't shuffle on every refresh.
            let ordered: [Item]
            if let compare {
                ordered = items.enumerated().sorted { x, y in
                    if compare(x.element, y.element) { return true }
                    if compare(y.element, x.element) { return false }
                    return x.offset < y.offset
                }.map(\.element)
            } else {
                ordered = items
            }
            var keys: [AnyHashable] = []
            keys.reserveCapacity(ordered.count)
            for item in ordered {
                let k = key(item)
                keys.append(k)
                p.values[k] = item
                p.flat.append(k)
                if let children {
                    let kids = level(children(item))
                    if !kids.isEmpty {
                        p.childKeys[k] = kids
                    }
                }
            }
            return keys
        }
        p.rootKeys = level(roots)
        return p
    }

    private func apply(_ p: Prepared, force: Bool) {
        guard let outline else { return }
        hasLoaded = hasLoaded || !p.flat.isEmpty
        if p.childKeys.isEmpty, !force, applyFlat(p, outline: outline) {
            return
        }
        if !force, !p.childKeys.isEmpty, applyTreeIncremental(p, outline: outline) {
            return
        }
        var newNodes: [AnyHashable: OutlineNode<Item>] = [:]
        newNodes.reserveCapacity(p.values.count)
        for (k, value) in p.values {
            let node = nodes[k] ?? OutlineNode(key: k, value: value)
            node.value = value
            newNodes[k] = node
        }
        func link(_ keys: [AnyHashable], parentNode: OutlineNode<Item>?) -> [OutlineNode<Item>] {
            keys.compactMap { k in
                guard let node = newNodes[k] else { return nil }
                node.parentNode = parentNode
                node.children = link(p.childKeys[k] ?? [], parentNode: node)
                return node
            }
        }
        rootNodes = link(p.rootKeys, parentNode: nil)
        nodes = newNodes

        if force || p.flat != flatKeys {
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
        flatKeys = p.flat
    }

    /// Fast path for flat lists: nodes act as row slots. Reordering only rebinds slots and redraws the
    /// visible cells; size changes become inserts/removes at the end. Avoids `reloadData`, which
    /// would rebuild every visible row view (and lose hover/scroll state) on each refresh.
    private func applyFlat(_ p: Prepared, outline: NSOutlineView) -> Bool {
        guard rootNodes.allSatisfy({ $0.children.isEmpty }), outline.numberOfRows == rootNodes.count else {
            return false
        }
        if p.flat == flatKeys {
            for node in rootNodes {
                if let v = p.values[node.key] { node.value = v }
            }
            refreshVisibleRows()
            return true
        }
        let selectedKeys = Set(selectedNodes().map(\.key))
        let oldCount = rootNodes.count
        let newCount = p.rootKeys.count
        suppressSelectionCallback = true
        outline.beginUpdates()
        if newCount > oldCount {
            for _ in oldCount..<newCount {
                rootNodes.append(OutlineNode(key: UUID(), value: p.values[p.rootKeys[0]]!))
            }
            outline.insertItems(at: IndexSet(oldCount..<newCount), inParent: nil, withAnimation: [])
        } else if newCount < oldCount {
            rootNodes.removeLast(oldCount - newCount)
            outline.removeItems(at: IndexSet(newCount..<oldCount), inParent: nil, withAnimation: [])
        }
        var newNodes: [AnyHashable: OutlineNode<Item>] = [:]
        newNodes.reserveCapacity(newCount)
        for (i, k) in p.rootKeys.enumerated() {
            let node = rootNodes[i]
            node.key = k
            node.value = p.values[k]!
            node.parentNode = nil
            newNodes[k] = node
        }
        outline.endUpdates()
        nodes = newNodes
        flatKeys = p.flat
        refreshVisibleRows()
        let rows = IndexSet(p.rootKeys.enumerated().compactMap { selectedKeys.contains($0.element) ? $0.offset : nil })
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
        suppressSelectionCallback = false
        if rows.count != selectedKeys.count {
            notifySelection()
        }
        return true
    }

    /// Incremental tree update: per-parent removals, inserts and moves instead of `reloadData`.
    /// Falls back (returns false) when a node moved to a different parent.
    private func applyTreeIncremental(_ p: Prepared, outline: NSOutlineView) -> Bool {
        guard !rootNodes.isEmpty || !p.rootKeys.isEmpty else { return false }
        // Parent of each key in the new structure.
        var newParent: [AnyHashable: AnyHashable?] = [:]
        newParent.reserveCapacity(p.values.count)
        for k in p.rootKeys { newParent[k] = .some(nil) }
        for (parentKey, kids) in p.childKeys {
            for k in kids { newParent[k] = .some(parentKey) }
        }
        // Reparenting is rare (orphans adopted by launchd); let reloadData handle it.
        for (k, node) in nodes {
            if let target = newParent[k], target != node.parentNode?.key {
                return false
            }
        }
        let selectedKeys = selectedNodes().map(\.key)
        for (k, node) in nodes {
            if let v = p.values[k] { node.value = v }
        }

        suppressSelectionCallback = true
        outline.beginUpdates()
        var created: [OutlineNode<Item>] = []

        func makeSubtree(_ k: AnyHashable, parentNode: OutlineNode<Item>?) -> OutlineNode<Item> {
            let node = OutlineNode(key: k, value: p.values[k]!)
            node.parentNode = parentNode
            nodes[k] = node
            node.children = (p.childKeys[k] ?? []).map { makeSubtree($0, parentNode: node) }
            created.append(node)
            return node
        }

        func sync(_ parentNode: OutlineNode<Item>?, target: [AnyHashable]) {
            var current = parentNode?.children ?? rootNodes
            func commit() {
                if let parentNode { parentNode.children = current } else { rootNodes = current }
            }
            // Removals (descending so indexes stay valid).
            let keep = Set(target)
            let removeIdx = IndexSet(current.indices.filter { !keep.contains(current[$0].key) })
            if !removeIdx.isEmpty {
                for i in removeIdx.reversed() {
                    forget(current[i])
                    current.remove(at: i)
                }
                commit()
                outline.removeItems(at: removeIdx, inParent: parentNode, withAnimation: [])
            }
            // Inserts and moves, left to right.
            for (i, k) in target.enumerated() {
                if i < current.count, current[i].key == k { continue }
                if let j = current[i...].firstIndex(where: { $0.key == k }) {
                    let node = current.remove(at: j)
                    current.insert(node, at: i)
                    commit()
                    outline.moveItem(at: j, inParent: parentNode, to: i, inParent: parentNode)
                } else {
                    current.insert(makeSubtree(k, parentNode: parentNode), at: i)
                    commit()
                    outline.insertItems(at: IndexSet(integer: i), inParent: parentNode, withAnimation: [])
                }
            }
            // Recurse into nodes that existed before (new subtrees are already complete).
            let fresh = Set(created.map { ObjectIdentifier($0) })
            for node in current where !fresh.contains(ObjectIdentifier(node)) {
                let kids = p.childKeys[node.key] ?? []
                if !kids.isEmpty || !node.children.isEmpty {
                    sync(node, target: kids)
                }
            }
        }

        func forget(_ node: OutlineNode<Item>) {
            nodes.removeValue(forKey: node.key)
            node.children.forEach(forget)
        }

        sync(nil, target: p.rootKeys)
        outline.endUpdates()
        flatKeys = p.flat
        if !created.isEmpty {
            restoreExpansion()
        }
        refreshVisibleRows()
        let rows = IndexSet(selectedKeys.compactMap { k -> Int? in
            guard let n = nodes[k] else { return nil }
            let r = outline.row(forItem: n)
            return r >= 0 ? r : nil
        })
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
        suppressSelectionCallback = false
        if rows.count != selectedKeys.count {
            notifySelection()
        }
        return true
    }

    private func restoreExpansion() {
        guard let outline, parent.children != nil else { return }
        func expand(_ list: [OutlineNode<Item>]) {
            for n in list where !n.children.isEmpty {
                let shouldExpand = parent.expandByDefault ? !collapsed.contains(n.key) : expandedExplicitly.contains(n.key)
                if shouldExpand {
                    if !outline.isItemExpanded(n) {
                        outline.expandItem(n)
                    }
                    expand(n.children)
                }
            }
        }
        expand(rootNodes)
    }

    private var expandedExplicitly = Set<AnyHashable>()

    func refreshVisibleRows() {
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
            (view as? TextCellView)?.setFont(appliedFont ?? TextCellView.defaultFont)
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
            let image = imageFn(node.value)
            if cell.imageView?.image !== image {
                cell.imageView?.image = image
            }
        }
        if let tip = spec.tooltip {
            let value = node.value
            cell.tooltipProvider = { tip(value) }
        } else {
            cell.tooltipProvider = nil
        }
    }

    private static var rowIdentifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("row") }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = outlineView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? ColoredRowView ?? {
            let r = ColoredRowView()
            r.identifier = Self.rowIdentifier
            return r
        }()
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

/// Table cell with optional icon. Uses manual frame layout (no Auto Layout) because cells are
/// created and reconfigured constantly while lists refresh.
final class TextCellView: NSTableCellView, NSViewToolTipOwner {
    static let defaultFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: .regular)
    private var lineHeight = ceil(defaultFont.ascender - defaultFont.descender + defaultFont.leading) + 1
    private let hasImage: Bool
    private var tipTag: NSView.ToolTipTag?

    /// Computed only when the user hovers, instead of on every refresh.
    var tooltipProvider: (() -> String?)? {
        didSet {
            if (oldValue == nil) != (tooltipProvider == nil) {
                needsLayout = true
            }
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) {
        hasImage = withImage
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.font = Self.defaultFont
        field.textColor = .labelColor
        addSubview(field)
        textField = field
        if withImage {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            addSubview(image)
            imageView = image
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFont(_ font: NSFont) {
        guard textField?.font != font else { return }
        textField?.font = font
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        needsLayout = true
    }

    static func make(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> TextCellView {
        TextCellView(identifier: identifier, withImage: withImage)
    }

    override func layout() {
        super.layout()
        let b = bounds
        var x: CGFloat = 2
        if hasImage, let imageView {
            imageView.frame = NSRect(x: 1, y: floor((b.height - 16) / 2), width: 16, height: 16)
            x = 21
        }
        let h = lineHeight
        textField?.frame = NSRect(x: x, y: floor((b.height - h) / 2), width: max(0, b.width - x - 2), height: h)
        if let tipTag {
            removeToolTip(tipTag)
            self.tipTag = nil
        }
        if tooltipProvider != nil {
            tipTag = addToolTip(b, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipProvider?() ?? ""
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
