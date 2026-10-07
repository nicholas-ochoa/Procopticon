import AppKit
import ProcopticonCore
import SwiftUI

/// A graph in the Resource History window.
enum HistoryElement: String, CaseIterable, Identifiable {
    case cpu
    case cores
    case gpu
    case memory
    case network
    case disk

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .cores: return "CPU Cores"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .disk: return "Disk"
        }
    }

    /// The shown elements, as comma-separated raw values.
    static let storageKey = "resourceHistoryElements"
    static let defaultValue = "cores,gpu,memory"

    static func parse(_ value: String) -> Set<HistoryElement> {
        Set(value.split(separator: ",").compactMap { HistoryElement(rawValue: String($0)) })
    }

    static func format(_ elements: Set<HistoryElement>) -> String {
        allCases.filter(elements.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// A floating, resizable window of Activity Monitor–style history graphs (CPU, each core, GPU,
/// memory, network and disk), chosen from a menu in its title bar.
@MainActor
final class ResourceHistoryWindow: NSObject, NSWindowDelegate {
    static let shared = ResourceHistoryWindow()
    static let onTopKey = "resourceHistoryOnTop"
    static let valuesKey = "resourceHistoryValues"
    /// Whether the window was open when Procopticon quit, so it reopens at launch.
    private static let openKey = "resourceHistoryOpen"
    private static let autosaveName = "ResourceHistory"
    private var panel: NSPanel?

    static func open() {
        shared.show(makeKey: true)
    }

    /// Reopens the window if it was open when Procopticon last quit, behind the main window.
    static func restore() {
        if UserDefaults.standard.bool(forKey: openKey) {
            shared.show(makeKey: false)
        }
    }

    static var isOpen: Bool {
        shared.panel?.isVisible == true
    }

    static func saveState() {
        UserDefaults.standard.set(isOpen, forKey: openKey)
    }

    func setOnTop(_ onTop: Bool) {
        panel?.level = onTop ? .floating : .normal
    }

    private func show(makeKey: Bool) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: ResourceHistoryView())
        controller.sizingOptions = []
        let panel = NSPanel(contentViewController: controller)
        panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        panel.title = "Resource History"
        // Panels hide while their app is inactive by default; this one stays up over other apps.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("resource-history")
        panel.contentMinSize = NSSize(width: 160, height: 90)
        let onTop = UserDefaults.standard.object(forKey: Self.onTopKey) as? Bool ?? true
        panel.level = onTop ? .floating : .normal

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        let button = NSHostingView(rootView: ResourceHistoryMenuButton())
        button.sizingOptions = []
        button.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
        accessory.view = button
        panel.addTitlebarAccessoryViewController(accessory)

        if !panel.setFrameUsingName(Self.autosaveName) {
            placeInitially(panel)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        self.panel = panel
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    /// Two tiles across, in the top-right corner of the screen.
    private func placeInitially(_ panel: NSPanel) {
        guard let screen = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        let elements = HistoryElement.parse(UserDefaults.standard.string(forKey: HistoryElement.storageKey) ?? HistoryElement.defaultValue)
        let cores = elements.contains(.cores) ? max(1, ProcessStore.shared.system.logicalCPUCount) : 0
        let others = elements.subtracting([.cores]).count
        let rows = (others + 1) / 2 + (cores + 1) / 2
        let width: CGFloat = 480
        let height = min(screen.height * 0.8, max(120, CGFloat(rows) * 100))
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 20, y: screen.maxY - 20))
    }

    func windowWillClose(_ notification: Notification) {
        // Release the window, so its graphs stop updating while it is closed.
        panel = nil
    }
}

/// The title bar menu button.
struct ResourceHistoryMenuButton: View {
    var body: some View {
        Menu {
            ResourceHistoryMenuItems()
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the graphs to show")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Graph choices, shared by the title bar menu and the window's context menu.
struct ResourceHistoryMenuItems: View {
    @AppStorage(HistoryElement.storageKey) private var elements = HistoryElement.defaultValue
    @AppStorage(ResourceHistoryWindow.valuesKey) private var showValues = true
    @AppStorage(ResourceHistoryWindow.onTopKey) private var onTop = true

    var body: some View {
        ForEach(HistoryElement.allCases) { element in
            Toggle(element.menuTitle, isOn: binding(element))
        }
        Divider()
        Toggle("Show Current Values", isOn: $showValues)
        Toggle("Always on Top", isOn: $onTop)
    }

    private func binding(_ element: HistoryElement) -> Binding<Bool> {
        Binding(
            get: { HistoryElement.parse(elements).contains(element) },
            set: { shown in
                var set = HistoryElement.parse(elements)
                if shown { set.insert(element) } else { set.remove(element) }
                elements = HistoryElement.format(set)
            })
    }
}

/// The graphs, as a grid of tiles that fills the window. The whole graphs come first, then one
/// tile per core on a new row.
struct ResourceHistoryView: View {
    @ObservedObject private var store = ProcessStore.shared
    @AppStorage(HistoryElement.storageKey) private var elements = HistoryElement.defaultValue
    @AppStorage(ResourceHistoryWindow.valuesKey) private var showValues = true
    @AppStorage(ResourceHistoryWindow.onTopKey) private var onTop = true

    private static let spacing: CGFloat = 3

    var body: some View {
        _ = store.revision
        let groups = tileGroups(store.system)
        return GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: Self.spacing, dy: Self.spacing)
            let frames = TileGrid.frames(groups: groups.map(\.count), in: bounds, spacing: Self.spacing)
            Canvas { context, _ in
                for (group, groupFrames) in zip(groups, frames) {
                    // Every tile in a group uses the same form of title: all "Core 5 — Performance"
                    // or all "Core 5".
                    let title = zip(group, groupFrames)
                        .map { $0.fittingTitle(in: context, frame: $1, showValue: showValues) }
                        .max() ?? 0
                    for (tile, frame) in zip(group, groupFrames) {
                        tile.draw(in: &context, frame: frame, title: title, showValue: showValues)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if HistoryElement.parse(elements).isEmpty {
                VStack(spacing: 4) {
                    Text("No graphs selected")
                    Text("Choose graphs from the \(Image(systemName: "ellipsis.circle")) menu.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            }
        }
        .contextMenu { ResourceHistoryMenuItems() }
        .onChange(of: onTop) { ResourceHistoryWindow.shared.setOnTop(onTop) }
    }

    private func tileGroups(_ sys: SystemMonitor) -> [[HistoryTile]] {
        let shown = HistoryElement.parse(elements)
        var whole: [HistoryTile] = []
        if shown.contains(.cpu) {
            whole.append(HistoryTile(
                titles: ["CPU"], value: percent(sys.cpuUsage),
                graph: .stacked([sys.cpuKernel.ordered, sys.cpuUser.ordered], colors: [HistoryTile.system, HistoryTile.user], max: 100)))
        }
        if shown.contains(.gpu) {
            let name = sys.last?.gpus.first?.name ?? ""
            whole.append(HistoryTile(
                titles: name.isEmpty ? ["GPU"] : [name, "GPU"], value: percent(sys.gpu.last),
                graph: .stacked([sys.gpu.ordered], colors: [HistoryTile.gpu], max: 100)))
        }
        if shown.contains(.memory) {
            let vm = sys.last?.vm
            let used = sys.memoryUsed.ordered, wired = sys.memoryWired.ordered, compressed = sys.memoryCompressed.ordered
            // Used memory is app memory plus wired plus compressed.
            let app = zip(used, zip(wired, compressed)).map { max(0, $0 - $1.0 - $1.1) }
            whole.append(HistoryTile(
                titles: ["Memory"], value: vm.map { "\(Fmt.bytes($0.usedBytes)) / \(Fmt.bytes($0.totalBytes))" } ?? "",
                graph: .stacked([wired, compressed, app], colors: [HistoryTile.wired, HistoryTile.compressed, HistoryTile.app],
                                max: Double(vm?.totalBytes ?? 1))))
        }
        if shown.contains(.network) {
            whole.append(HistoryTile(
                titles: ["Network"], value: "↓ \(rate(sys.netInRate))  ↑ \(rate(sys.netOutRate))",
                graph: .mirrored(up: sys.netIn.ordered, down: sys.netOut.ordered)))
        }
        if shown.contains(.disk) {
            whole.append(HistoryTile(
                titles: ["Disk"], value: "R \(rate(sys.diskReadRate))  W \(rate(sys.diskWriteRate))",
                graph: .mirrored(up: sys.diskRead.ordered, down: sys.diskWrite.ordered)))
        }
        var cores: [HistoryTile] = []
        if shown.contains(.cores) {
            let types = MachineInfo.current.coreTypes
            for (i, history) in sys.perCore.enumerated() {
                let kernel = sys.perCoreKernel.indices.contains(i) ? sys.perCoreKernel[i].ordered : []
                let total = history.ordered
                let user = zip(total, kernel).map { max(0, $0 - $1) }
                let name = "Core \(i + 1)"
                cores.append(HistoryTile(
                    titles: types.indices.contains(i) ? ["\(name) — \(types[i])", name] : [name], value: percent(history.last),
                    graph: .stacked([kernel, user], colors: [HistoryTile.system, HistoryTile.user], max: 100)))
            }
        }
        return [whole, cores]
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func rate(_ value: Double) -> String {
        Fmt.rate(value).ifEmpty("0 B/s")
    }
}

/// Places tile groups in a grid with the same number of columns for every group, each group
/// starting on a new row. The column count is the one that gives tiles closest to Activity
/// Monitor's proportions with the fewest empty cells; tiles in a group's last, partial row share
/// its full width.
enum TileGrid {
    static let aspectRatio: CGFloat = 2.3

    static func frames(groups: [Int], in bounds: CGRect, spacing: CGFloat) -> [[CGRect]] {
        let columns = bestColumns(groups: groups, size: bounds.size, spacing: spacing)
        let rows = groups.reduce(0) { $0 + rowCount($1, columns) }
        guard rows > 0 else {
            return groups.map { _ in [] }
        }
        let height = (bounds.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        var result: [[CGRect]] = []
        var row = 0
        for count in groups {
            var frames: [CGRect] = []
            for index in 0..<count {
                let inRow = min(columns, count - index / columns * columns)
                let width = (bounds.width - CGFloat(inRow - 1) * spacing) / CGFloat(inRow)
                frames.append(CGRect(x: bounds.minX + CGFloat(index % columns) * (width + spacing),
                                     y: bounds.minY + CGFloat(row + index / columns) * (height + spacing),
                                     width: width, height: height))
            }
            result.append(frames)
            row += rowCount(count, columns)
        }
        return result
    }

    static func bestColumns(groups: [Int], size: CGSize, spacing: CGFloat) -> Int {
        var best = (columns: 1, score: CGFloat.infinity)
        for columns in 1...max(1, groups.max() ?? 1) {
            let rows = groups.reduce(0) { $0 + rowCount($1, columns) }
            let width = (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let height = (size.height - CGFloat(max(0, rows - 1)) * spacing) / CGFloat(max(1, rows))
            guard width > 0, height > 0 else { continue }
            let empty = CGFloat(rows * columns - groups.reduce(0, +)) / CGFloat(max(1, rows * columns))
            let score = abs(log(width / height / aspectRatio)) + empty
            if score < best.score {
                best = (columns, score)
            }
        }
        return best.columns
    }

    private static func rowCount(_ count: Int, _ columns: Int) -> Int {
        (count + columns - 1) / columns
    }
}

/// One graph: a black tile of lit blocks, one column per sample with the newest at the right, and
/// a title in the top-left corner.
struct HistoryTile {
    enum Graph {
        /// Series stacked from the bottom, first series lowest.
        case stacked([[Double]], colors: [Color], max: Double)
        /// `up` rises from the middle and `down` falls from it, on a shared automatic scale.
        case mirrored(up: [Double], down: [Double])
    }

    /// Longest first; the longest that fits is drawn.
    var titles: [String]
    var value: String
    var graph: Graph

    static let user = Color(red: 0.30, green: 0.85, blue: 0.25)
    static let system = Color(red: 0.95, green: 0.22, blue: 0.17)
    static let gpu = Color(red: 0.17, green: 0.56, blue: 1.0)
    static let app = Color(red: 1.0, green: 0.72, blue: 0.15)
    static let wired = system
    static let compressed = Color(red: 0.72, green: 0.42, blue: 1.0)
    static let received = Color(red: 0.20, green: 0.80, blue: 0.95)
    static let sent = system

    /// Each sample is a column 3 points wide; each block is 2 points tall. Both have 1-point gaps.
    private static let columnPitch: CGFloat = 4
    private static let columnWidth: CGFloat = 3
    private static let blockPitch: CGFloat = 3
    private static let blockHeight: CGFloat = 2
    /// The smallest full scale of a mirrored graph, so idle traffic doesn't fill it.
    private static let minimumMirroredScale = 16.0 * 1024

    /// Draws the tile with `titles[title]`, or the shortest title if it has fewer.
    func draw(in context: inout GraphicsContext, frame: CGRect, title: Int, showValue: Bool) {
        context.fill(Path(frame), with: .color(.black))
        let area = frame.insetBy(dx: 2, dy: 2)
        let columns = max(0, Int((area.width + Self.columnPitch - Self.columnWidth) / Self.columnPitch))
        let blocks = Int((area.height + Self.blockPitch - Self.blockHeight) / Self.blockPitch)
        guard columns > 0, blocks > 0 else { return }
        switch graph {
        case .stacked(let series, let colors, let maxValue):
            var paths = Array(repeating: Path(), count: series.count)
            let count = series.map(\.count).min() ?? 0
            for column in 0..<min(columns, count) {
                var total = 0.0
                var lit = 0
                for (s, values) in series.enumerated() {
                    total += values[values.count - 1 - column]
                    let top = min(blocks, Int((total / max(maxValue, 0.0001) * Double(blocks)).rounded()))
                    addBlocks(&paths[s], column: column, from: lit, to: top, area: area)
                    lit = max(lit, top)
                }
            }
            for (path, color) in zip(paths, colors) {
                context.fill(path, with: .color(color))
            }
        case .mirrored(let up, let down):
            let half = blocks / 2
            let shown = min(columns, up.count, down.count)
            let scale = max(up.suffix(shown).max() ?? 0, down.suffix(shown).max() ?? 0, Self.minimumMirroredScale)
            let middle = area.maxY - CGFloat(half) * Self.blockPitch
            var upPath = Path(), downPath = Path()
            for column in 0..<shown {
                let upBlocks = Int((up[up.count - 1 - column] / scale * Double(half)).rounded())
                let downBlocks = Int((down[down.count - 1 - column] / scale * Double(half)).rounded())
                addBlocks(&upPath, column: column, from: half, to: half + upBlocks, area: area)
                addBlocks(&downPath, column: column, from: half - downBlocks, to: half, area: area)
            }
            context.fill(upPath, with: .color(Self.received))
            context.fill(downPath, with: .color(Self.sent))
            context.fill(Path(CGRect(x: area.minX, y: middle, width: area.width, height: 1)), with: .color(.white.opacity(0.18)))
        }
        drawLabels(in: &context, frame: frame, title: title, showValue: showValue)
    }

    /// Lights blocks `from..<to` (counted from the bottom) of a column (counted from the right).
    private func addBlocks(_ path: inout Path, column: Int, from: Int, to: Int, area: CGRect) {
        guard to > from else { return }
        let x = area.maxX - CGFloat(column) * Self.columnPitch - Self.columnWidth
        for block in from..<to {
            let y = area.maxY - CGFloat(block) * Self.blockPitch - Self.blockHeight
            path.addRect(CGRect(x: x, y: y, width: Self.columnWidth, height: Self.blockHeight))
        }
    }

    /// The index of the longest title that fits beside the value, or of the shortest title.
    func fittingTitle(in context: GraphicsContext, frame: CGRect, showValue: Bool) -> Int {
        let labels = Labels(self, context: context, frame: frame, showValue: showValue)
        return labels.titles.firstIndex { labels.width($0) + labels.valueWidth <= labels.available } ?? titles.count - 1
    }

    private func drawLabels(in context: inout GraphicsContext, frame: CGRect, title index: Int, showValue: Bool) {
        let labels = Labels(self, context: context, frame: frame, showValue: showValue)
        guard let title = labels.titles.indices.contains(index) ? labels.titles[index] : labels.titles.last else { return }
        let titleWidth = labels.width(title)
        // Drop the value when the title leaves no room for it.
        let valueWidth = titleWidth + labels.valueWidth <= labels.available ? labels.valueWidth : 0
        let origin = CGPoint(x: frame.minX + Labels.inset, y: frame.minY + 4)
        context.drawLayer { layer in
            layer.clip(to: Path(frame))
            // A dark backing keeps labels legible over tall bars; on the black tile it is invisible.
            func backing(_ rect: CGRect) {
                layer.fill(Path(roundedRect: rect.insetBy(dx: -3, dy: -1), cornerRadius: 3), with: .color(.black.opacity(0.7)))
            }
            backing(CGRect(origin: origin, size: CGSize(width: min(titleWidth, labels.available), height: labels.height(title))))
            if valueWidth > 0 {
                let width = valueWidth - Labels.valueGap
                backing(CGRect(x: frame.maxX - Labels.inset - width, y: origin.y, width: width, height: labels.height(labels.value)))
            }
            layer.addFilter(.shadow(color: .black, radius: 1.5))
            layer.draw(title, at: origin, anchor: .topLeading)
            if valueWidth > 0 {
                layer.draw(labels.value, at: CGPoint(x: frame.maxX - Labels.inset, y: origin.y), anchor: .topTrailing)
            }
        }
    }

    /// A tile's title and value text, resolved for its size.
    private struct Labels {
        static let inset: CGFloat = 6
        static let valueGap: CGFloat = 10
        /// Unbounded, so text wider than the tile measures at its full width.
        private static let unbounded = CGSize(width: 100_000, height: 100_000)

        let titles: [GraphicsContext.ResolvedText]
        let value: GraphicsContext.ResolvedText
        let available: CGFloat
        /// The value's width plus the gap before it; 0 when the value is hidden.
        let valueWidth: CGFloat

        init(_ tile: HistoryTile, context: GraphicsContext, frame: CGRect, showValue: Bool) {
            let size: CGFloat = frame.height < 50 ? 10 : 12
            titles = tile.titles.map {
                context.resolve(Text($0).font(.system(size: size, weight: .medium)).foregroundStyle(.white))
            }
            value = context.resolve(Text(tile.value).font(.system(size: size - 1).monospacedDigit()).foregroundStyle(.white.opacity(0.7)))
            available = frame.width - Self.inset * 2
            valueWidth = showValue && !tile.value.isEmpty ? value.measure(in: Self.unbounded).width + Self.valueGap : 0
        }

        func width(_ text: GraphicsContext.ResolvedText) -> CGFloat {
            text.measure(in: Self.unbounded).width
        }

        func height(_ text: GraphicsContext.ResolvedText) -> CGFloat {
            text.measure(in: Self.unbounded).height
        }
    }
}
