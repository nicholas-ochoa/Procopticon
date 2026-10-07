import AppKit
import ProcopticonCore
import SwiftUI

/// Small live graph shown in the menu bar.
struct MenuBarLabel: View {
    @ObservedObject private var store = ProcessStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Image(nsImage: MenuBarGraphRenderer.image(kind: settings.menuBarGraph, sys: store.system))
    }
}

enum MenuBarGraphRenderer {
    static func image(kind: AppSettings.MenuBarGraphKind, sys: SystemMonitor) -> NSImage {
        let size = NSSize(width: kind == .cpuAndMemory ? 38 : 26, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.25).setStroke()
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            frame.lineWidth = 1
            frame.stroke()
            let inner = rect.insetBy(dx: 1.5, dy: 1.5)
            switch kind {
            case .cpu:
                draw(sys.cpuTotal.ordered, max: 100, in: inner)
            case .memory:
                let total = Double(sys.last?.vm.totalBytes ?? 1)
                draw(sys.memoryUsed.ordered, max: total, in: inner)
            case .cpuAndMemory:
                let half = NSRect(x: inner.minX, y: inner.minY, width: inner.width / 2 - 1, height: inner.height)
                draw(sys.cpuTotal.ordered, max: 100, in: half)
                let total = Double(sys.last?.vm.totalBytes ?? 1)
                draw(sys.memoryUsed.ordered, max: total, in: half.offsetBy(dx: inner.width / 2 + 1, dy: 0))
            case .network:
                let m = max(sys.netIn.maxValue, sys.netOut.maxValue, 1)
                draw(sys.netIn.ordered, max: m, in: inner)
                draw(sys.netOut.ordered, max: m, in: inner, alpha: 0.5)
            case .disk:
                let m = max(sys.diskRead.maxValue, sys.diskWrite.maxValue, 1)
                draw(sys.diskRead.ordered, max: m, in: inner)
                draw(sys.diskWrite.ordered, max: m, in: inner, alpha: 0.5)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ values: [Double], max m: Double, in rect: NSRect, alpha: CGFloat = 1) {
        let slice = values.suffix(Int(rect.width))
        guard !slice.isEmpty else { return }
        NSColor.black.withAlphaComponent(alpha).setFill()
        for (i, v) in slice.enumerated() {
            let h = CGFloat(min(1, max(0, v / max(m, 0.0001)))) * rect.height
            let x = rect.maxX - CGFloat(slice.count - i)
            NSRect(x: x, y: rect.minY, width: 1, height: max(h, v > 0 ? 0.5 : 0)).fill()
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject private var store = ProcessStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let sys = store.system
        let vm = sys.last?.vm
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Procopticon").font(.headline)
                Spacer()
                Text(Elevation.shared.mode.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            GraphView(series: [GraphSeries(values: sys.cpuKernel.ordered, color: .red, label: "Kernel"),
                               GraphSeries(values: sys.cpuUser.ordered, color: .green, label: "User")],
                      maxValue: 100, capacity: 120, title: "CPU", valueText: String(format: "%.1f%%", sys.cpuUsage),
                      formatter: { String(format: "%.1f%%", $0) }, stacked: true)
                .frame(height: 60)
            GraphView(series: [GraphSeries(values: sys.memoryUsed.ordered, color: .orange)],
                      maxValue: Double(vm?.totalBytes ?? 1), capacity: 120, title: "Memory",
                      valueText: vm.map { "\(Fmt.bytes($0.usedBytes)) / \(Fmt.bytes($0.totalBytes))" } ?? "",
                      formatter: { Fmt.bytes($0) })
                .frame(height: 60)
            Text("Top CPU").font(.subheadline.weight(.semibold))
            ForEach(top, id: \.key) { p in
                Button {
                    activateMain()
                    ProcessSelection.shared.reveal(pid: p.pid)
                } label: {
                    HStack {
                        Image(nsImage: ProcessIcons.icon(for: p.record))
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", p.cpu)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(p.name) (\(p.pid)) in the process list")
            }
            Divider()
            HStack {
                Button("Show Procopticon") { activateMain() }
                    .help("Bring the process list to the front")
                Button("System Information") { SystemInfoWindow.open(); NSApp.activate() }
                    .help("Open the CPU, memory, disk, network, GPU and power graphs")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .help("Quit Procopticon")
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private var top: [ProcessItem] {
        Array(store.items.values.filter { !$0.isRemoved }.sorted { $0.cpu > $1.cpu }.prefix(6))
    }

    private func activateMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
