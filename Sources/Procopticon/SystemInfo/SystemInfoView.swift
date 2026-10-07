import AppKit
import ProcopticonCore
import SwiftUI

@MainActor
enum SystemInfoWindow {
    static func open() {
        WindowManager.shared.show(id: "sysinfo", title: "System Information", size: NSSize(width: 940, height: 640), autosave: "SystemInformation") {
            SystemInfoView()
        }
    }
}

struct SystemInfoView: View {
    @ObservedObject private var store = ProcessStore.shared
    @AppStorage("sysinfoSection") private var section: Section = .summary

    enum Section: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case cpu = "CPU"
        case memory = "Memory"
        case disk = "Disk"
        case network = "Network"
        case gpu = "GPU"
        case power = "Power"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .summary: return "square.grid.2x2"
            case .cpu: return "cpu"
            case .memory: return "memorychip"
            case .disk: return "internaldrive"
            case .network: return "network"
            case .gpu: return "display"
            case .power: return "bolt.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            ScrollView {
                Group {
                    switch section {
                    case .summary: SummaryPanel(sys: store.system, store: store, revision: store.revision)
                    case .cpu: CPUPanel(sys: store.system, store: store, revision: store.revision)
                    case .memory: MemoryPanel(sys: store.system, revision: store.revision)
                    case .disk: DiskPanel(sys: store.system, revision: store.revision)
                    case .network: NetworkPanel(sys: store.system, revision: store.revision)
                    case .gpu: GPUPanel(sys: store.system, revision: store.revision)
                    case .power: PowerPanel(sys: store.system, revision: store.revision)
                    }
                }
                .padding()
            }
        }
    }
}

private func percent(_ v: Double) -> String { String(format: "%.1f%%", v) }

struct SummaryPanel: View {
    let sys: SystemMonitor
    let store: ProcessStore
    /// Changes every sample so SwiftUI re-evaluates the panel (the monitor is a reference type).
    let revision: Int

    var body: some View {
        let vm = sys.last?.vm
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                GraphView(series: [GraphSeries(values: sys.cpuKernel.ordered, color: .red, label: "Kernel"),
                                   GraphSeries(values: sys.cpuUser.ordered, color: .green, label: "User")],
                          maxValue: 100, title: "CPU", valueText: percent(sys.cpuUsage),
                          formatter: { String(format: "%.1f%%", $0) }, tooltips: sys.topCPUProcess, stacked: true)
                    .frame(height: 130)
                GraphView(series: [GraphSeries(values: sys.memoryUsed.ordered, color: .orange, label: "Used")],
                          maxValue: Double(vm?.totalBytes ?? 1), title: "Memory",
                          valueText: vm.map { "\(Fmt.bytes($0.usedBytes)) / \(Fmt.bytes($0.totalBytes))" } ?? "",
                          formatter: { Fmt.bytes($0) })
                    .frame(height: 130)
                GraphView(series: [GraphSeries(values: sys.diskRead.ordered, color: .blue, label: "Read"),
                                   GraphSeries(values: sys.diskWrite.ordered, color: .pink, label: "Write")],
                          title: "Disk", valueText: "R \(Fmt.rate(sys.diskReadRate).ifEmpty("0")) · W \(Fmt.rate(sys.diskWriteRate).ifEmpty("0"))",
                          formatter: { Fmt.rate($0).ifEmpty("0") }, tooltips: sys.topIOProcess)
                    .frame(height: 130)
                GraphView(series: [GraphSeries(values: sys.netIn.ordered, color: .teal, label: "In"),
                                   GraphSeries(values: sys.netOut.ordered, color: .purple, label: "Out")],
                          title: "Network", valueText: "↓ \(Fmt.rate(sys.netInRate).ifEmpty("0")) · ↑ \(Fmt.rate(sys.netOutRate).ifEmpty("0"))",
                          formatter: { Fmt.rate($0).ifEmpty("0") })
                    .frame(height: 130)
                GraphView(series: [GraphSeries(values: sys.gpu.ordered, color: .indigo, label: "GPU")],
                          maxValue: 100, title: "GPU", valueText: percent(sys.gpu.last), formatter: { String(format: "%.0f%%", $0) },
                          tooltips: sys.topGPUProcess)
                    .frame(height: 130)
                GraphView(series: [GraphSeries(values: sys.power.ordered, color: .yellow, label: "Processes")],
                          title: "Process energy", valueText: Fmt.watts(sys.processPower).ifEmpty("0 W"), formatter: { Fmt.watts($0).ifEmpty("0 W") })
                    .frame(height: 130)
            }
            MachineSummary(store: store)
        }
    }
}

struct MachineSummary: View {
    let store: ProcessStore

    var body: some View {
        let m = MachineInfo.current
        let boot = store.system.last?.bootTime ?? 0
        SectionBox(title: "System") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                InfoRow("Host name", m.hostName)
                InfoRow("Model", m.modelIdentifier)
                InfoRow("Operating system", m.osVersion)
                InfoRow("Processor", "\(m.cpuBrand) — \(m.performanceCores)P + \(m.efficiencyCores)E cores (\(m.logicalCores) logical)")
                InfoRow("Physical memory", Fmt.bytes(m.memoryBytes))
                InfoRow("Uptime", boot > 0 ? Fmt.relative(seconds: Date().timeIntervalSince1970 - boot) : "")
                InfoRow("Kernel", m.kernelVersion)
            }
        }
    }
}

struct CPUPanel: View {
    let sys: SystemMonitor
    let store: ProcessStore
    /// Changes every sample so SwiftUI re-evaluates the panel (the monitor is a reference type).
    let revision: Int
    @AppStorage("sysinfoPerCore") private var perCore = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GraphView(series: [GraphSeries(values: sys.cpuKernel.ordered, color: .red, label: "Kernel"),
                               GraphSeries(values: sys.cpuUser.ordered, color: .green, label: "User")],
                      maxValue: 100, title: "CPU usage", valueText: percent(sys.cpuUsage),
                      formatter: { String(format: "%.1f%%", $0) }, tooltips: sys.topCPUProcess, stacked: true)
                .frame(height: 180)
            Toggle("Show one graph per CPU", isOn: $perCore).toggleStyle(.checkbox)
            if perCore {
                let m = MachineInfo.current
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(6, max(2, sys.perCore.count / 2))), spacing: 6) {
                    ForEach(Array(sys.perCore.enumerated()), id: \.offset) { i, h in
                        let kind = i < m.efficiencyCores && m.efficiencyCores > 0 ? "E" : "P"
                        GraphView(series: [GraphSeries(values: h.ordered, color: .green)], maxValue: 100,
                                  title: "CPU \(i) (\(kind))", valueText: percent(h.last), formatter: { String(format: "%.0f%%", $0) })
                            .frame(height: 70)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                SectionBox(title: "Usage") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Total", percent(sys.cpuUsage))
                        InfoRow("User", percent(sys.cpuUserUsage))
                        InfoRow("Kernel", percent(sys.cpuKernelUsage))
                        InfoRow("Load average", (sys.last?.loadAverage ?? []).map { String(format: "%.2f", $0) }.joined(separator: "  "))
                        InfoRow("Processes", "\(store.processCount)")
                        InfoRow("Threads", Fmt.count(store.totalThreads))
                    }
                }
                SectionBox(title: "Top processes") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(store.items.values.filter { !$0.isRemoved }.sorted { $0.cpu > $1.cpu }.prefix(8), id: \.key) { p in
                            HStack {
                                Image(nsImage: ProcessIcons.icon(for: p.record))
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f%%", p.cpu)).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MemoryPanel: View {
    let sys: SystemMonitor
    /// Changes every sample so SwiftUI re-evaluates the panel (the monitor is a reference type).
    let revision: Int

    var body: some View {
        let vm = sys.last?.vm
        VStack(alignment: .leading, spacing: 12) {
            GraphView(series: [GraphSeries(values: sys.memoryUsed.ordered, color: .orange, label: "Used"),
                               GraphSeries(values: sys.memoryCompressed.ordered, color: .purple, label: "Compressed"),
                               GraphSeries(values: sys.memoryWired.ordered, color: .red, label: "Wired")],
                      maxValue: Double(vm?.totalBytes ?? 1), title: "Physical memory",
                      valueText: vm.map { "\(Fmt.bytes($0.usedBytes)) of \(Fmt.bytes($0.totalBytes))" } ?? "",
                      formatter: { Fmt.bytes($0) })
                .frame(height: 180)
            GraphView(series: [GraphSeries(values: sys.swapUsed.ordered, color: .brown, label: "Swap")],
                      maxValue: max(Double(vm?.swapTotal ?? 0), 1), title: "Swap",
                      valueText: vm.map { "\(Fmt.bytes($0.swapUsed)) of \(Fmt.bytes($0.swapTotal))" } ?? "", formatter: { Fmt.bytes($0) })
                .frame(height: 90)
            if let vm {
                HStack(alignment: .top, spacing: 12) {
                    SectionBox(title: "Breakdown") {
                        VStack(alignment: .leading, spacing: 6) {
                            bar("App memory", vm.appMemory, vm.totalBytes, .orange)
                            bar("Wired", vm.wiredBytes, vm.totalBytes, .red)
                            bar("Compressed", vm.compressedBytes, vm.totalBytes, .purple)
                            bar("Cached files", vm.cachedFiles, vm.totalBytes, .blue)
                            bar("Free", vm.freeBytes, vm.totalBytes, .green)
                        }
                    }
                    SectionBox(title: "Activity") {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                            InfoRow("Memory pressure", vm.pressureDescription)
                            InfoRow("Compressed (original size)", Fmt.bytes(vm.compressedUncompressed * vm.pageSize))
                            InfoRow("Page faults/s", Fmt.count(Int(sys.faultsRate)))
                            InfoRow("Page-ins/s", Fmt.count(Int(sys.pageinsRate)))
                            InfoRow("Page-outs/s", Fmt.count(Int(sys.pageoutsRate)))
                            InfoRow("Compressions/s", Fmt.count(Int(sys.compressionsRate)))
                            InfoRow("Decompressions/s", Fmt.count(Int(sys.decompressionsRate)))
                            InfoRow("Swap-ins/s", Fmt.count(Int(sys.swapinsRate)))
                            InfoRow("Swap-outs/s", Fmt.count(Int(sys.swapoutsRate)))
                            InfoRow("Page size", Fmt.bytes(vm.pageSize))
                        }
                    }
                }
            }
        }
    }

    private func bar(_ title: String, _ value: UInt64, _ total: UInt64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(Fmt.bytes(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            UsageBar(fraction: Double(value) / Double(max(1, total)), color: color)
        }
    }
}

struct DiskPanel: View {
    let sys: SystemMonitor
    /// Changes every sample so SwiftUI re-evaluates the panel (the monitor is a reference type).
    let revision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GraphView(series: [GraphSeries(values: sys.diskRead.ordered, color: .blue, label: "Read"),
                               GraphSeries(values: sys.diskWrite.ordered, color: .pink, label: "Write")],
                      title: "Disk throughput", valueText: "R \(Fmt.rate(sys.diskReadRate).ifEmpty("0")) · W \(Fmt.rate(sys.diskWriteRate).ifEmpty("0"))",
                      formatter: { Fmt.rate($0).ifEmpty("0") }, tooltips: sys.topIOProcess)
                .frame(height: 180)
            SectionBox(title: "Activity") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    InfoRow("Reads/s", Fmt.count(Int(sys.diskReadOpsRate)))
                    InfoRow("Writes/s", Fmt.count(Int(sys.diskWriteOpsRate)))
                    InfoRow("Total read", Fmt.bytes(sys.last?.disk.bytesRead ?? 0))
                    InfoRow("Total written", Fmt.bytes(sys.last?.disk.bytesWritten ?? 0))
                }
            }
            SectionBox(title: "Volumes") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(volumes(), id: \.path) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(v.name).fontWeight(.medium)
                                Text(v.path).foregroundStyle(.secondary).font(.caption)
                                Spacer()
                                Text("\(Fmt.bytes(v.total - v.free)) used of \(Fmt.bytes(v.total)) · \(v.format)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            UsageBar(fraction: Double(v.total - v.free) / Double(max(1, v.total)), color: .blue)
                        }
                    }
                }
            }
        }
    }

    struct Volume {
        var name: String
        var path: String
        var total: UInt64
        var free: UInt64
        var format: String
    }

    private func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage.map { UInt64($0) } ?? UInt64(v.volumeAvailableCapacity ?? 0)
            return Volume(name: v.volumeName ?? url.lastPathComponent, path: url.path, total: UInt64(total),
                          free: min(free, UInt64(total)), format: v.volumeLocalizedFormatDescription ?? "")
        }
    }
}

struct NetworkPanel: View {
    let sys: SystemMonitor
    /// Changes every sample so SwiftUI re-evaluates the panel (the monitor is a reference type).
    let revision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GraphView(series: [GraphSeries(values: sys.netIn.ordered, color: .teal, label: "Received"),
                               GraphSeries(values: sys.netOut.ordered, color: .purple, label: "Sent")],
                      title: "Network throughput", valueText: "↓ \(Fmt.rate(sys.netInRate).ifEmpty("0")) · ↑ \(Fmt.rate(sys.netOutRate).ifEmpty("0"))",
                      formatter: { Fmt.rate($0).ifEmpty("0") })
                .frame(height: 180)
            SectionBox(title: "Interfaces") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Interface").bold()
                        Text("Status").bold()
                        Text("Receive").bold()
                        Text("Send").bold()
                        Text("Total received").bold()
                        Text("Total sent").bold()
                        Text("Errors").bold()
                    }
                    ForEach(interfaces, id: \.name) { i in
                        let rate = sys.interfaceRates[i.name]
                        let total = sys.interfaceTotals[i.name]
                        GridRow {
                            Text(i.name)
                            Text(i.isUp ? "Up" : "Down").foregroundStyle(i.isUp ? .green : .secondary)
                            Text(Fmt.rate(rate?.rx ?? 0).ifEmpty("—")).monospacedDigit()
                            Text(Fmt.rate(rate?.tx ?? 0).ifEmpty("—")).monospacedDigit()
                            Text(Fmt.bytes(total?.bytesIn ?? i.ibytes)).monospacedDigit()
                            Text(Fmt.bytes(total?.bytesOut ?? i.obytes)).monospacedDigit()
                            Text("\(i.ierrors + i.oerrors)").monospacedDigit()
                        }
                    }
                }
            }
            SectionBox(title: "Packets") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    InfoRow("Received/s", Fmt.count(Int(sys.netInPacketsRate)))
                    InfoRow("Sent/s", Fmt.count(Int(sys.netOutPacketsRate)))
                }
            }
        }
    }

    private var interfaces: [NetInterfaceStats] {
        (sys.last?.interfaces ?? []).filter { $0.ibytes > 0 || $0.obytes > 0 || $0.isUp }
            .sorted { traffic($0) > traffic($1) }
    }

    private func traffic(_ i: NetInterfaceStats) -> UInt64 {
        let t = sys.interfaceTotals[i.name]
        return (t?.bytesIn ?? i.ibytes) &+ (t?.bytesOut ?? i.obytes)
    }
}

struct GPUPanel: View {
    let sys: SystemMonitor
    /// Changes every sample so SwiftUI re-evaluates the panel (the monitor is a reference type).
    let revision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GraphView(series: [GraphSeries(values: sys.gpu.ordered, color: .indigo, label: "Utilization")], maxValue: 100,
                      title: "GPU utilization", valueText: percent(sys.gpu.last), formatter: { String(format: "%.0f%%", $0) },
                      tooltips: sys.topGPUProcess)
                .frame(height: 180)
            ForEach(Array((sys.last?.gpus ?? []).enumerated()), id: \.offset) { _, g in
                SectionBox(title: g.name) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        if let cores = g.coreCount {
                            InfoRow("GPU cores", "\(cores)")
                        }
                        InfoRow("Device utilization", String(format: "%.0f%%", g.utilization))
                        InfoRow("Renderer utilization", String(format: "%.0f%%", g.rendererUtilization))
                        InfoRow("Tiler utilization", String(format: "%.0f%%", g.tilerUtilization))
                        InfoRow("Memory in use", Fmt.bytes(g.memoryUsed))
                        InfoRow("Memory allocated", Fmt.bytes(g.memoryAllocated))
                    }
                }
            }
            SectionBox(title: "Processes using the GPU") {
                let top = topProcesses
                if top.isEmpty {
                    Text("No process has used the GPU since Procopticon started watching.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow {
                            Text("Process")
                            Text("GPU").gridColumnAlignment(.trailing)
                            Text("GPU time").gridColumnAlignment(.trailing)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(top, id: \.key) { p in
                            GridRow {
                                Button { PropertiesWindow.open(p, tab: .performance) } label: {
                                    Label {
                                        Text("\(p.displayName)  \(Text(String(p.pid)).foregroundStyle(.secondary))")
                                    } icon: {
                                        Image(nsImage: ProcessIcons.icon(for: p.record))
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Open the process's properties")
                                Text(p.gpu > 0 ? String(format: "%.1f%%", p.gpu) : "")
                                Text(Fmt.duration(nanoseconds: p.gpuTimeNs))
                            }
                            .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    /// The busiest processes now, then those that used the most GPU time.
    private var topProcesses: [ProcessItem] {
        ProcessStore.shared.items.values
            .filter { !$0.isRemoved && $0.gpuTimeNs > 0 }
            .sorted { ($0.gpu, $0.gpuTimeNs) > ($1.gpu, $1.gpuTimeNs) }
            .prefix(12)
            .map { $0 }
    }
}

struct PowerPanel: View {
    let sys: SystemMonitor
    /// Changes every sample so SwiftUI re-evaluates the panel (the monitor is a reference type).
    let revision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GraphView(series: [GraphSeries(values: sys.power.ordered, color: .yellow, label: "Processes")],
                      title: "Estimated process power", valueText: Fmt.watts(sys.processPower).ifEmpty("0 W"),
                      formatter: { Fmt.watts($0).ifEmpty("0 W") })
                .frame(height: 180)
            if let b = sys.last?.battery, b.present {
                SectionBox(title: "Battery") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Charge", String(format: "%.0f%%", b.percent))
                        InfoRow("Power source", b.onAC ? (b.charging ? "Power adapter (charging)" : "Power adapter") : "Battery")
                        InfoRow("Time remaining", b.timeRemainingMinutes > 0 && b.timeRemainingMinutes < 65535 ? "\(b.timeRemainingMinutes / 60)h \(b.timeRemainingMinutes % 60)m" : "Calculating…")
                        InfoRow("Battery power", String(format: "%.2f W", b.watts))
                        InfoRow("Cycle count", "\(b.cycleCount)")
                        InfoRow("Health", b.designCapacity > 0 ? String(format: "%.0f%% (%d / %d mAh)", Double(b.maxCapacity) / Double(b.designCapacity) * 100, b.maxCapacity, b.designCapacity) : "")
                        InfoRow("Temperature", String(format: "%.1f °C", b.temperatureC))
                    }
                }
            } else {
                Text("No battery present.").foregroundStyle(.secondary)
            }
        }
    }
}
