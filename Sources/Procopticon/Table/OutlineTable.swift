import AppKit
import ProcopticonCore
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
    /// Colored version of `text`, shown in place of it (sorting, filtering and copying still use
    /// `text`). Only its colors are used; the cell supplies the font.
    var attributedText: ((Item) -> NSAttributedString)?
    /// Ascending comparator; nil disables sorting by this column.
    var less: ((Item, Item) -> Bool)?
    var image: ((Item) -> NSImage?)?
    var tooltip: ((Item) -> String?)?
    /// Shown in a styled panel (see `RichToolTipController`) in place of a standard tooltip.
    var richTooltip: ((Item) -> AnyView)?
    var graph: ((Item) -> GraphCellData?)?
    var help: String?
    /// The value written by an export (see `TableExport`); nil exports `text`, or null when empty.
    var exportValue: ((Item) -> ExportValue)?
    /// The unit of exported numbers, e.g. "bytes" or "%".
    var exportUnit: String?

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

    /// Convenience: numeric column sorted by a numeric key, which is also what it exports.
    static func number<V: Comparable>(_ id: String, _ title: String, width: CGFloat = 80, visible: Bool = true, help: String? = nil,
                                     value: @escaping (Item) -> V, text: @escaping (Item) -> String) -> TableColumnSpec {
        var spec = TableColumnSpec(id, title, width: width, align: .right, visible: visible, help: help, text: text,
                                   less: { value($0) < value($1) })
        spec.exportValue = { ExportValue(value($0), text: text($0)) }
        return spec
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

/// Lays a table out the way AppKit apps such as Activity Monitor do: its scroll view runs up under the
/// toolbar and an optional bar of filter controls, with the column header just below them. The
/// toolbar, filter bar and column header then share one background, and rows scroll under them.
struct TableUnderToolbar<Bar: View, Table: View>: View {
    @ViewBuilder var bar: Bar
    var table: (_ topInset: CGFloat) -> Table
    @State private var barHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                table(proxy.safeAreaInsets.top + barHeight)
                    .ignoresSafeArea(.container, edges: .top)
                bar
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
        }
    }
}

extension TableUnderToolbar where Bar == EmptyView {
    init(table: @escaping (_ topInset: CGFloat) -> Table) {
        self.init(bar: { EmptyView() }, table: table)
    }
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
    /// Set by `TableUnderToolbar`: the height of the bars the scroll view runs under. The column
    /// header and first row start below them.
    var topInset: CGFloat?

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
        // Rows paint their own stripes (ColoredRowView.isOddRow): the table's built-in ones are drawn
        // across the whole visible area and repainted whenever rows move, which made each refresh of a
        // tree sorted by a changing column several times slower.
        outline.usesAlternatingRowBackgroundColors = false
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
        outline.headerView = ResizeCursorHeaderView()

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
        outline.richToolTip = { [weak coordinator] row, column in coordinator?.richToolTip(row: row, column: column) }
        coordinator.iconObserver = NotificationCenter.default.addObserver(
            forName: ProcessIcons.didLoadNotification, object: nil, queue: .main) { [weak coordinator] _ in
            coordinator?.refreshVisibleRows()
        }
        scroll.documentView = outline
        scroll.isHidden = !isActive
        applyTopInset(to: scroll)
        coordinator.applyFont()
        coordinator.reload(force: true)
        coordinator.bindController()
        return scroll
    }

    private func applyTopInset(to scroll: NSScrollView) {
        guard let topInset else { return }
        scroll.automaticallyAdjustsContentInsets = false
        if scroll.contentInsets.top != topInset {
            scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
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
        applyTopInset(to: nsView)
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
    fileprivate var exportHandler: (() -> ExportTable)?
    fileprivate var revealHandler: ((AnyHashable) -> Bool)?
    fileprivate var focusHandler: (() -> Void)?
    fileprivate var followHandler: (() -> Void)?

    /// The row kept in view, together with its expanded descendants, after every update.
    var followedKey: AnyHashable? {
        didSet { if followedKey != nil, followedKey != oldValue { followHandler?() } }
    }

    /// The visible columns and rows in display order, or nil before the table exists.
    func exportTable() -> ExportTable? { exportHandler?() }

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
        controller.exportHandler = { [weak self] in self?.exportTable() ?? ExportTable(columns: [], rows: []) }
        controller.revealHandler = { [weak self] key in self?.reveal(key) ?? false }
        controller.focusHandler = { [weak self] in
            guard let outline = self?.outline else { return }
            outline.window?.makeFirstResponder(outline)
        }
        controller.followHandler = { [weak self] in self?.startFollowing() }
    }

    /// Expands the followed row (and the rows above it) so its children show, then scrolls to it.
    private func startFollowing() {
        guard let outline, let key = parent.controller?.followedKey, let node = nodes[key] else { return }
        var chain = [node]
        var p = node.parentNode
        while let n = p {
            chain.insert(n, at: 0)
            p = n.parentNode
        }
        for n in chain where !n.children.isEmpty && !outline.isItemExpanded(n) {
            outline.expandItem(n)
        }
        scrollToFollowed()
    }

    /// Scrolls as little as possible to show the followed row and its expanded descendants; when they
    /// don't all fit, the followed row goes to the top. Does nothing while the row is filtered out or
    /// inside a collapsed parent.
    private func scrollToFollowed() {
        guard let outline, !outline.isHiddenOrHasHiddenAncestor, let key = parent.controller?.followedKey,
              let node = nodes[key], let scroll = outline.enclosingScrollView else { return }
        let first = outline.row(forItem: node)
        guard first >= 0 else { return }
        var lastNode = node
        while outline.isItemExpanded(lastNode), let child = lastNode.children.last {
            lastNode = child
        }
        let last = max(first, outline.row(forItem: lastNode))
        let visibleRows = max(1, outline.rows(in: scroll.documentVisibleRect).length)
        // Bring the bottom of the range into view, then the followed row: the second call only
        // scrolls back up when the range is taller than the view.
        outline.scrollRowToVisible(min(last, first + visibleRows - 1))
        outline.scrollRowToVisible(first)
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
        let resetSort = ClosureMenuItem(title: "Reset Sort Order") { [weak self] in
            self?.sortColumn = nil
            self?.outline?.sortDescriptors = []
            self?.saveSort()
            self?.reload(force: true)
        }
        resetSort.toolTip = "Stop sorting by a column; rows go back to their default order"
        menu.addItem(resetSort)
        let sizeToFit = ClosureMenuItem(title: "Size Columns to Fit") { [weak self] in
            self?.sizeColumnsToFit()
        }
        sizeToFit.toolTip = "Resize the visible columns to fit their titles and contents"
        menu.addItem(sizeToFit)
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
                if let view = outline.view(atColumn: index, row: row, makeIfNecessary: true) as? TextCellView {
                    var w = view.fittingWidth
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
            scrollToFollowed()
            return
        }
        Self.prepareQueue.async { [weak self] in
            let prepared = work()
            DispatchQueue.main.async {
                guard let self, gen == self.prepareGeneration else { return }
                self.apply(prepared, force: force)
                self.scrollToFollowed()
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
        // A node can change parent while the row order stays the same (a process that daemonized
        // moving from under its exited parent to just after it), and the outline must hear of that
        // too; otherwise its child counts drift from ours and a later removal throws.
        var reparented = false
        func link(_ keys: [AnyHashable], parentNode: OutlineNode<Item>?) -> [OutlineNode<Item>] {
            keys.compactMap { k in
                guard let node = newNodes[k] else { return nil }
                if node.parentNode !== parentNode { reparented = true }
                node.parentNode = parentNode
                node.children = link(p.childKeys[k] ?? [], parentNode: node)
                return node
            }
        }
        rootNodes = link(p.rootKeys, parentNode: nil)
        nodes = newNodes
        pruneExpansionState()

        if force || reparented || p.flat != flatKeys {
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
        pruneExpansionState()
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
        // Hundreds of new rows (e.g. clearing a search): reloading and expanding in bulk is cheaper
        // than inserting and expanding subtree by subtree. (Removals are cheap either way.)
        var kept = 0
        for k in p.values.keys where nodes[k] != nil {
            kept += 1
        }
        if p.values.count - kept > 200 {
            return false
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
            // Inserts and the fewest moves (see ListReorder): rows already in order stay put, so a
            // process changing rank moves one row, not every row between its old and new place.
            if current.map(\.key) != target {
                for step in ListReorder.steps(from: current.map(\.key), to: target) {
                    switch step {
                    case .move(let from, let to):
                        let node = current.remove(at: from)
                        current.insert(node, at: to)
                        commit()
                        outline.moveItem(at: from, inParent: parentNode, to: to, inParent: parentNode)
                    case .insert(let at, let targetIndex):
                        current.insert(makeSubtree(target[targetIndex], parentNode: parentNode), at: at)
                        commit()
                        outline.insertItems(at: IndexSet(integer: at), inParent: parentNode, withAnimation: [])
                    }
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
            expandNew(created)
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

    /// Expands newly inserted nodes (`created` lists children before their parents), and parents
    /// that just gained their first children. Walking the whole tree instead, on every refresh that
    /// adds a process, kept the main thread busy.
    private func expandNew(_ created: [OutlineNode<Item>]) {
        guard let outline, parent.children != nil else { return }
        let fresh = Set(created.map { ObjectIdentifier($0) })
        for node in created {
            if let joined = node.parentNode, !fresh.contains(ObjectIdentifier(joined)), shouldExpand(joined), !outline.isItemExpanded(joined) {
                outline.expandItem(joined)
            }
        }
        for node in created.reversed() where !node.children.isEmpty && shouldExpand(node) && !outline.isItemExpanded(node) {
            outline.expandItem(node)
        }
    }

    private func shouldExpand(_ node: OutlineNode<Item>) -> Bool {
        parent.expandByDefault ? !collapsed.contains(node.key) : expandedExplicitly.contains(node.key)
    }

    /// Expands nodes under `list` (the whole tree by default) as the user left them.
    private func restoreExpansion(_ list: [OutlineNode<Item>]? = nil) {
        guard let outline, parent.children != nil else { return }
        // Nothing collapsed by hand (the usual case): one bulk call instead of one per node, each
        // of which updates the table's rows.
        if list == nil, parent.expandByDefault, collapsed.isEmpty {
            outline.expandItem(nil, expandChildren: true)
            return
        }
        func expand(_ list: [OutlineNode<Item>]) {
            for n in list where !n.children.isEmpty {
                if shouldExpand(n) {
                    if !outline.isItemExpanded(n) {
                        outline.expandItem(n)
                    }
                    expand(n.children)
                }
            }
        }
        expand(list ?? rootNodes)
    }

    private var expandedExplicitly = Set<AnyHashable>()

    /// Forgets the expansion state of rows long gone. Every process ever expanded or collapsed
    /// stayed in these sets for as long as the window lived. Rows only filtered out for now keep
    /// their state, so this waits until the sets have clearly outgrown the list.
    private func pruneExpansionState() {
        guard collapsed.count + expandedExplicitly.count > 2 * nodes.count + 1024 else { return }
        collapsed = collapsed.filter { nodes[$0] != nil }
        expandedExplicitly = expandedExplicitly.filter { nodes[$0] != nil }
    }

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
        restripe()
    }

    /// Updates each row's stripe for its position; rows shift when others are inserted, removed,
    /// expanded or collapsed above them.
    func restripe() {
        outline?.enumerateAvailableRowViews { rowView, row in
            (rowView as? ColoredRowView)?.isOddRow = row % 2 == 1
        }
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? ColoredRowView)?.isOddRow = row % 2 == 1
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
        cell.alignment = spec.alignment
        if let attributed = spec.attributedText {
            cell.setText(attributed(node.value))
        } else {
            cell.setText(spec.text(node.value))
        }
        if let imageFn = spec.image {
            cell.image = imageFn(node.value)
        }
        if let tip = spec.tooltip {
            let value = node.value
            cell.tooltipProvider = { tip(value) }
        } else {
            cell.tooltipProvider = nil
        }
        cell.showsToolTip = spec.richTooltip == nil
    }

    /// Builder for the rich tooltip of a cell, or nil when its column has none.
    func richToolTip(row: Int, column: Int) -> (() -> AnyView)? {
        guard let outline, outline.tableColumns.indices.contains(column),
              let tip = columnMap[outline.tableColumns[column].identifier.rawValue]?.richTooltip,
              let node = outline.item(atRow: row) as? OutlineNode<Item> else { return nil }
        let value = node.value
        return { tip(value) }
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
        scheduleRestripe()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? OutlineNode<Item> {
            collapsed.remove(node.key)
            expandedExplicitly.insert(node.key)
        }
        scheduleRestripe()
    }

    private var restripeScheduled = false

    /// Expanding a whole tree posts one notification per node; restripe once afterwards.
    private func scheduleRestripe() {
        guard !restripeScheduled else { return }
        restripeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.restripeScheduled = false
            self?.restripe()
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
    func exportTable() -> ExportTable {
        guard let outline else { return ExportTable(columns: [], rows: []) }
        let visible = outline.tableColumns.filter { !$0.isHidden }.compactMap { columnMap[$0.identifier.rawValue] }
            .filter { $0.kind == .text }
        var rows: [[ExportValue]] = []
        rows.reserveCapacity(outline.numberOfRows)
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? OutlineNode<Item> else { continue }
            rows.append(visible.map { spec in
                if let export = spec.exportValue { return export(node.value) }
                let text = spec.text(node.value)
                return text.isEmpty ? .null : .string(text)
            })
        }
        return ExportTable(columns: visible.map { ExportTable.Column(title: $0.title, unit: $0.exportUnit) }, rows: rows)
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

    // The table draws nothing itself (rows paint their own backgrounds and the selection), so it
    // gets a plain layer color instead of a backing store that moving rows would repaint.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.alternatingContentBackgroundColors[0].cgColor
    }
    var copyHandler: (() -> Void)?
    /// Rich tooltip for the cell at (row, column), if it has one.
    var richToolTip: ((_ row: Int, _ column: Int) -> (() -> AnyView)?)?
    private let toolTips = RichToolTipController()
    private var toolTipArea: NSTrackingArea?

    private struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    override func keyDown(with event: NSEvent) {
        toolTips.dismiss()
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Rich tooltips

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let toolTipArea {
            removeTrackingArea(toolTipArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        toolTipArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === toolTipArea {
            updateToolTip(event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolTip(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === toolTipArea {
            toolTips.pointerMoved(over: nil) { nil }
        }
    }

    override func mouseDown(with event: NSEvent) {
        toolTips.dismiss(keepingArea: true)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        toolTips.dismiss(keepingArea: true)
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        toolTips.dismiss(keepingArea: true)
        super.otherMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        toolTips.dismiss()
        super.scrollWheel(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        toolTips.dismiss()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidHide() {
        toolTips.dismiss()
        super.viewDidHide()
    }

    private func updateToolTip(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        guard row >= 0, column >= 0, isUnobstructed(event), let content = richToolTip?(row, column) else {
            toolTips.pointerMoved(over: nil) { nil }
            return
        }
        toolTips.pointerMoved(over: Cell(row: row, column: column)) { content() }
    }

    /// False over the column header, toolbar or filter bar, which the table scrolls under.
    private func isUnobstructed(_ event: NSEvent) -> Bool {
        guard let frameView = window?.contentView?.superview else { return false }
        return frameView.hitTest(event.locationInWindow)?.isDescendant(of: self) == true
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

    /// Alternating stripe, shown by the row rather than the table (see `makeNSView`) through the row
    /// view's `backgroundColor`. Set it every time a row view is placed: the table resets a reused
    /// row view's background, even when its parity is unchanged.
    var isOddRow = false {
        didSet { applyStripe() }
    }

    private func applyStripe() {
        let stripes = NSColor.alternatingContentBackgroundColors
        let color = stripes[isOddRow ? 1 % stripes.count : 0]
        if backgroundColor != color {
            backgroundColor = color
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // One layer per row instead of one per cell: far less for Core Animation to commit.
        canDrawSubviewsIntoLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Fills `backgroundColor`, the stripe.
        super.drawBackground(in: dirtyRect)
        if let highlightColor {
            highlightColor.setFill()
            bounds.fill()
        }
    }
}

/// Column header that shows the column-resize cursor over the edges between columns. AppKit's own
/// cursor rects for this don't take effect in these SwiftUI-hosted windows, so the header tracks the
/// pointer and sets the cursor itself.
final class ResizeCursorHeaderView: NSTableHeaderView {
    private var trackingArea: NSTrackingArea?
    private var showingResizeCursor = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCursor(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if showingResizeCursor {
            showingResizeCursor = false
            NSCursor.arrow.set()
        }
    }

    private func updateCursor(_ event: NSEvent) {
        let overEdge = isOverResizableEdge(convert(event.locationInWindow, from: nil))
        if overEdge {
            NSCursor.columnResize.set()
        } else if showingResizeCursor {
            NSCursor.arrow.set()
        }
        showingResizeCursor = overEdge
    }

    /// Within a few points of the right edge of a column the user can resize.
    private func isOverResizableEdge(_ point: NSPoint) -> Bool {
        guard let table = tableView, table.allowsColumnResizing else { return false }
        for (index, column) in table.tableColumns.enumerated()
        where !column.isHidden && column.resizingMask.contains(.userResizingMask) {
            if abs(point.x - headerRect(ofColumn: index).maxX) <= 4 {
                return true
            }
        }
        return false
    }
}

/// Table cell that draws its optional icon and one line of text itself. Cells built from an
/// NSTextField and NSImageView cost three views and layers each, plus the text field cell's
/// appearance machinery; a screenful of a dozen columns is hundreds of them, and creating, laying
/// out and committing them dominated the main thread on refreshes and scrolling.
final class TextCellView: NSTableCellView, NSViewToolTipOwner {
    static let defaultFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: .regular)
    private let hasImage: Bool
    private var tipTag: NSView.ToolTipTag?
    private(set) var font = TextCellView.defaultFont
    private(set) var string = ""
    /// Colored text being shown, if any; see `setText(_: NSAttributedString)`.
    private var styledText: NSAttributedString?

    /// Computed only when the user hovers, instead of on every refresh. Without one, a cell whose
    /// text is cut off shows its full text instead.
    var tooltipProvider: (() -> String?)?
    /// Off where the table shows a rich tooltip instead.
    var showsToolTip = true

    var alignment: NSTextAlignment = .left {
        didSet {
            if alignment != oldValue { invalidate() }
        }
    }

    var image: NSImage? {
        didSet {
            if image !== oldValue { needsDisplay = true }
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) {
        hasImage = withImage
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func make(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> TextCellView {
        TextCellView(identifier: identifier, withImage: withImage)
    }

    func setFont(_ font: NSFont) {
        guard font != self.font else { return }
        self.font = font
        invalidate()
    }

    func setText(_ text: String) {
        guard styledText != nil || string != text else { return }
        styledText = nil
        string = text
        invalidate()
    }

    /// Shows text in the colors of its `.foregroundColor` runs, in the cell's font. A selected row
    /// shows it uncolored, since its highlight would drown the colors out.
    func setText(_ text: NSAttributedString) {
        guard styledText?.isEqual(to: text) != true else { return }
        styledText = text
        string = text.string
        invalidate()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            if backgroundStyle != oldValue { invalidate() }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        // The text is truncated to the width (see `makeLine`) and the tooltip covers the bounds.
        invalidate()
        if let tipTag {
            removeToolTip(tipTag)
        }
        tipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    private func invalidate() {
        line = nil
        needsDisplay = true
    }

    private var textRect: NSRect {
        let b = bounds
        let x: CGFloat = hasImage ? 23 : 4
        let height = ceil(font.ascender - font.descender + font.leading)
        return NSRect(x: x, y: floor((b.height - height) / 2), width: max(0, b.width - x - 4), height: height)
    }

    private var textColor: NSColor {
        backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
    }

    /// The text typeset once, truncated to the cell and positioned for its alignment; drawing it
    /// is then cheap. Rebuilt after anything that changes it (`invalidate()`).
    private struct Line {
        var line: CTLine
        var x: CGFloat
    }
    private var line: Line?

    /// The text in the cell's font and colors. Strings far longer than the cell (command lines run
    /// to thousands of characters) are cut to what could fit first, since only their start shows.
    /// Colors are resolved now, in the cell's appearance, for Core Text.
    private func coloredText(maxWidth: CGFloat) -> NSAttributedString {
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let base = textColor.cgColor
        // No glyph is narrower than about a quarter of the font size.
        let fits = Int(maxWidth / max(1, font.pointSize * 0.25)) + 1
        let text: NSMutableAttributedString
        if let styledText, backgroundStyle != .emphasized {
            text = NSMutableAttributedString(attributedString: styledText)
            if text.length > fits {
                text.deleteCharacters(in: NSRange(location: fits, length: text.length - fits))
            }
            let range = NSRange(location: 0, length: text.length)
            text.enumerateAttribute(.foregroundColor, in: range) { color, run, _ in
                text.addAttribute(colorKey, value: (color as? NSColor)?.cgColor ?? base, range: run)
            }
            text.addAttribute(.font, value: font, range: range)
        } else {
            let visible = string.utf16.count > fits ? String(string.prefix(fits)) : string
            text = NSMutableAttributedString(string: visible, attributes: [.font: font, colorKey: base])
        }
        return text
    }

    private func makeLine(in rect: NSRect) -> Line {
        let text = coloredText(maxWidth: rect.width)
        var line = CTLineCreateWithAttributedString(text)
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > rect.width, text.length > 0 {
            let ellipsis = NSAttributedString(string: "…", attributes: text.attributes(at: max(0, text.length - 1), effectiveRange: nil))
            if let truncated = CTLineCreateTruncatedLine(line, Double(rect.width), .end, CTLineCreateWithAttributedString(ellipsis)) {
                line = truncated
                width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
        let x: CGFloat = switch alignment {
        case .right: rect.maxX - width
        case .center: rect.midX - width / 2
        default: rect.minX
        }
        return Line(line: line, x: x)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        if hasImage, let image {
            let slot = NSRect(x: 1, y: floor((bounds.height - 16) / 2), width: 16, height: 16)
            let rect = Self.aspectFit(image.size, in: slot)
            if image.isTemplate {
                drawTinted(image, in: rect)
            } else {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        guard !string.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = textRect
        let line = self.line ?? makeLine(in: rect)
        self.line = line
        // Baseline centered on the font's line height.
        let ascent = font.ascender, descent = -font.descender
        let top = rect.minY + (rect.height - ascent - descent) / 2
        context.saveGState()
        if isFlipped {
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: line.x, y: top + ascent)
        } else {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: line.x, y: top + descent)
        }
        CTLineDraw(line.line, context)
        context.restoreGState()
    }

    private static func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Template images (SF Symbols) take the text color, as an image view would give them.
    private func drawTinted(_ image: NSImage, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        textColor.set()
        rect.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Width the text needs on one line (for sizing columns to fit).
    var fittingWidth: CGFloat {
        let text = NSAttributedString(string: string, attributes: [.font: font])
        return ceil(text.size().width) + textRect.minX + 4
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { string }

    // MARK: Tooltips

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard showsToolTip else { return "" }
        if let tip = tooltipProvider?(), !tip.isEmpty {
            return tip
        }
        // Cut off: show the whole text.
        let full = NSAttributedString(string: string, attributes: [.font: font])
        return full.size().width > textRect.width ? string : ""
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
