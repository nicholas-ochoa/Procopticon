import AppKit
import ProcopticonCore
import SwiftUI

/// A section of the summary panel above the status bar, opened from its stats in the status bar.
enum SummarySection: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case network = "Network"
    case gpu = "GPU"

    var id: String { rawValue }

    /// The open section; empty when the panel is closed.
    static let storageKey = "summarySection"
}

/// Activity Monitor–style summary of one resource: totals and rates either side of a history graph.
struct StatusSummaryPanel: View {
    let section: SummarySection
    @ObservedObject private var store = ProcessStore.shared
    @AppStorage("summaryDiskGraph") private var diskGraph = DiskGraph.io
    @AppStorage("summaryNetworkGraph") private var networkGraph = NetworkGraph.packets

    enum DiskGraph: String, CaseIterable {
        case io = "IO"
        case data = "Data"
    }

    enum NetworkGraph: String, CaseIterable {
        case packets = "Packets"
        case data = "Data"
    }

    static let inColor = Color.cyan
    static let outColor = Color.red

    var body: some View {
        _ = store.revision
        let sys = store.system
        return HStack(spacing: 0) {
            switch section {
            case .cpu: cpu(sys)
            case .memory: memory(sys)
            case .disk: disk(sys)
            case .network: network(sys)
            case .gpu: gpu(sys)
            }
        }
        .frame(height: 104)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .frame(maxWidth: 820)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: Sections

    @ViewBuilder
    private func cpu(_ sys: SystemMonitor) -> some View {
        let load = sys.last?.loadAverage ?? []
        SummaryStats(rows: [
            .init("System", percent(sys.cpuKernelUsage), color: Self.outColor),
            .init("User", percent(sys.cpuUserUsage), color: Self.inColor),
            .init("Idle", percent(max(0, 100 - sys.cpuUsage))),
        ])
        Divider()
        SummaryGraph(title: Text("CPU LOAD"), style: .stacked(bottom: sys.cpuKernel.ordered, top: sys.cpuUser.ordered, max: 100))
        Divider()
        SummaryStats(rows: [
            .init("Threads", Fmt.count(store.totalThreads)),
            .init("Processes", Fmt.count(store.processCount)),
            .init("Load average", load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: "  ")),
        ])
    }

    @ViewBuilder
    private func memory(_ sys: SystemMonitor) -> some View {
        let vm = sys.last?.vm
        SummaryGraph(title: Text("MEMORY PRESSURE"),
                     style: .pressure(sys.memoryPressure.ordered, levels: sys.memoryPressureLevel.ordered))
        Divider()
        SummaryStats(rows: [
            .init("Physical memory", vm.map { Fmt.bytes($0.totalBytes) } ?? ""),
            .init("Memory used", vm.map { Fmt.bytes($0.usedBytes) } ?? ""),
            .init("Cached files", vm.map { Fmt.bytes($0.cachedFiles) } ?? ""),
            .init("Swap used", vm.map { Fmt.bytes($0.swapUsed) } ?? ""),
        ])
        Divider()
        SummaryStats(rows: [
            .init("App memory", vm.map { Fmt.bytes($0.appMemory) } ?? ""),
            .init("Wired memory", vm.map { Fmt.bytes($0.wiredBytes) } ?? ""),
            .init("Compressed", vm.map { Fmt.bytes($0.compressedBytes) } ?? ""),
            .init("Pressure", vm.map { "\($0.pressureDescription) (\(100 - min(100, max(0, Int($0.availablePercent))))%)" } ?? "",
                  color: vm.map { Self.pressureColor(Double($0.pressureLevel)) }),
        ])
    }

    @ViewBuilder
    private func disk(_ sys: SystemMonitor) -> some View {
        let d = sys.last?.disk
        SummaryStats(rows: [
            .init("Reads in", d.map { Fmt.count($0.opsRead) } ?? ""),
            .init("Writes out", d.map { Fmt.count($0.opsWritten) } ?? ""),
            .init("Reads in/sec", Fmt.count(Int(sys.diskReadOpsRate.rounded())), color: Self.inColor),
            .init("Writes out/sec", Fmt.count(Int(sys.diskWriteOpsRate.rounded())), color: Self.outColor),
        ])
        Divider()
        SummaryGraph(title: modeMenu($diskGraph),
                     style: diskGraph == .io
                        ? .mirrored(in: sys.diskReadOps.ordered, out: sys.diskWriteOps.ordered)
                        : .mirrored(in: sys.diskRead.ordered, out: sys.diskWrite.ordered))
        Divider()
        SummaryStats(rows: [
            .init("Data read", d.map { Fmt.bytes($0.bytesRead) } ?? ""),
            .init("Data written", d.map { Fmt.bytes($0.bytesWritten) } ?? ""),
            .init("Data read/sec", rate(sys.diskReadRate), color: Self.inColor),
            .init("Data written/sec", rate(sys.diskWriteRate), color: Self.outColor),
        ])
    }

    @ViewBuilder
    private func network(_ sys: SystemMonitor) -> some View {
        SummaryStats(rows: [
            .init("Packets in", Fmt.count(sys.netPacketsIn)),
            .init("Packets out", Fmt.count(sys.netPacketsOut)),
            .init("Packets in/sec", Fmt.count(Int(sys.netInPacketsRate.rounded())), color: Self.inColor),
            .init("Packets out/sec", Fmt.count(Int(sys.netOutPacketsRate.rounded())), color: Self.outColor),
        ])
        Divider()
        SummaryGraph(title: modeMenu($networkGraph),
                     style: networkGraph == .packets
                        ? .mirrored(in: sys.netInPackets.ordered, out: sys.netOutPackets.ordered)
                        : .mirrored(in: sys.netIn.ordered, out: sys.netOut.ordered))
        Divider()
        SummaryStats(rows: [
            .init("Data received", Fmt.bytes(sys.netBytesIn)),
            .init("Data sent", Fmt.bytes(sys.netBytesOut)),
            .init("Data received/sec", rate(sys.netInRate), color: Self.inColor),
            .init("Data sent/sec", rate(sys.netOutRate), color: Self.outColor),
        ])
    }

    @ViewBuilder
    private func gpu(_ sys: SystemMonitor) -> some View {
        let g = sys.last?.gpus.first
        let top = store.items.values.filter { !$0.isRemoved && $0.gpu > 0 }.max { $0.gpu < $1.gpu }
        SummaryStats(rows: [
            .init("Utilization", g.map { String(format: "%.0f%%", $0.utilization) } ?? "", color: .indigo),
            .init("Renderer", g.map { String(format: "%.0f%%", $0.rendererUtilization) } ?? ""),
            .init("Tiler", g.map { String(format: "%.0f%%", $0.tilerUtilization) } ?? ""),
        ])
        Divider()
        SummaryGraph(title: Text("GPU"), style: .area(sys.gpu.ordered, max: 100, color: .indigo))
        Divider()
        SummaryStats(rows: [
            .init("GPU", g.map { gpu in gpu.coreCount.map { "\(gpu.name), \($0) cores" } ?? gpu.name } ?? ""),
            .init("Memory in use", g.map { Fmt.bytes($0.memoryUsed) } ?? ""),
            .init("Busiest process", top.map { String(format: "%@ %.1f%%", $0.displayName, $0.gpu) } ?? "None"),
        ])
    }

    // MARK: Helpers

    /// Graph title that switches what the graph plots, like Activity Monitor's "IO ⌃". An AppKit
    /// menu, since this panel updates every refresh (see `NativeMenuButton`).
    private func modeMenu<Mode: RawRepresentable & CaseIterable & Hashable>(_ mode: Binding<Mode>) -> some View
    where Mode.RawValue == String, Mode.AllCases: RandomAccessCollection {
        NativeMenuButton(menu: {
            let menu = NSMenu()
            for option in Mode.allCases {
                menu.add(option.rawValue, state: option == mode.wrappedValue ? .on : .off) { mode.wrappedValue = option }
            }
            return menu
        }) {
            HStack(spacing: 2) {
                Text(mode.wrappedValue.rawValue.uppercased())
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose what the graph shows")
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    private func rate(_ value: Double) -> String {
        Fmt.rate(value).ifEmpty("0 B/s")
    }

    static func pressureColor(_ level: Double) -> Color {
        switch level {
        case 4...: return .red
        case 2..<4: return .yellow
        default: return .green
        }
    }
}

/// Label/value rows separated by hairlines.
private struct SummaryStats: View {
    struct Row {
        var label: String
        var value: String
        var color: Color?

        init(_ label: String, _ value: String, color: Color? = nil) {
            self.label = label
            self.value = value
            self.color = color
        }
    }

    let rows: [Row]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider()
                }
                HStack {
                    Text(row.label + ":")
                    Spacer(minLength: 12)
                    Text(row.value.isEmpty ? "—" : row.value)
                        .monospacedDigit()
                        .foregroundStyle(row.color ?? .primary)
                }
                .lineLimit(1)
                .frame(maxHeight: .infinity)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 190, maxWidth: 260)
    }
}

/// Two points per sample, so the graph shows as much history as fits.
private let summaryGraphStep: CGFloat = 2

/// History graph for the summary panel, newest sample at the right.
private struct SummaryGraph<Title: View>: View {
    enum Style {
        /// `bottom` stacked under `top` (CPU system and user).
        case stacked(bottom: [Double], top: [Double], max: Double)
        /// `in` above the center line and `out` below it, on a shared scale (disk, network).
        case mirrored(in: [Double], out: [Double])
        /// Memory pressure, colored by the pressure level of each sample.
        case pressure([Double], levels: [Double])
        case area([Double], max: Double, color: Color)
    }

    let title: Title
    let style: Style

    var body: some View {
        VStack(spacing: 2) {
            title
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: 16)
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 170, maxWidth: 280)
    }


    private func points(_ values: [Double], width: CGFloat) -> ArraySlice<Double> {
        values.suffix(Int(width / summaryGraphStep) + 1)
    }

    private func x(_ index: Int, count: Int, width: CGFloat) -> CGFloat {
        width - CGFloat(count - 1 - index) * summaryGraphStep
    }

    private func area(_ values: ArraySlice<Double>, base: [Double]? = nil, width: CGFloat, y: (Double) -> CGFloat) -> Path {
        var path = Path()
        let count = values.count
        guard count > 1 else { return path }
        let start = values.startIndex
        path.move(to: CGPoint(x: x(0, count: count, width: width), y: y(base?[0] ?? 0)))
        for i in 0..<count {
            path.addLine(to: CGPoint(x: x(i, count: count, width: width), y: y(values[start + i] + (base?[i] ?? 0))))
        }
        for i in stride(from: count - 1, through: 0, by: -1) {
            path.addLine(to: CGPoint(x: x(i, count: count, width: width), y: y(base?[i] ?? 0)))
        }
        path.closeSubpath()
        return path
    }

    private func fill(_ context: inout GraphicsContext, _ path: Path, _ color: Color) {
        context.fill(path, with: .color(color.opacity(0.45)))
        context.stroke(path, with: .color(color), lineWidth: 1)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        switch style {
        case .stacked(let bottom, let top, let maxValue):
            let b = points(bottom, width: w), t = points(top, width: w)
            let n = min(b.count, t.count)
            let bb = b.suffix(n), tt = t.suffix(n)
            let y = { (v: Double) in h - CGFloat(min(1, v / maxValue)) * (h - 2) }
            fill(&context, area(tt, base: Array(bb), width: w, y: y), StatusSummaryPanel.inColor)
            fill(&context, area(bb, width: w, y: y), StatusSummaryPanel.outColor)
        case .mirrored(let input, let output):
            let i = points(input, width: w), o = points(output, width: w)
            let peak = max(i.max() ?? 0, o.max() ?? 0, 1)
            let mid = h / 2
            fill(&context, area(i, width: w) { mid - CGFloat($0 / peak) * (mid - 1) }, StatusSummaryPanel.inColor)
            fill(&context, area(o, width: w) { mid + CGFloat($0 / peak) * (mid - 1) }, StatusSummaryPanel.outColor)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: mid))
            line.addLine(to: CGPoint(x: w, y: mid))
            context.stroke(line, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
        case .pressure(let values, let levels):
            let v = points(values, width: w)
            let l = levels.suffix(v.count)
            let y = { (value: Double) in h - CGFloat(min(1, value / 100)) * (h - 2) }
            // One bar per sample, colored by that sample's level.
            for (offset, value) in v.enumerated() {
                let level = l.isEmpty ? 1 : l[l.startIndex + min(offset, l.count - 1)]
                let px = x(offset, count: v.count, width: w)
                let rect = CGRect(x: px - summaryGraphStep, y: y(value), width: summaryGraphStep, height: h - y(value))
                context.fill(Path(rect), with: .color(StatusSummaryPanel.pressureColor(level).opacity(0.7)))
            }
        case .area(let values, let maxValue, let color):
            let v = points(values, width: w)
            fill(&context, area(v, width: w) { h - CGFloat(min(1, $0 / maxValue)) * (h - 2) }, color)
        }
    }
}
