import AppKit
import ProcopticonCore
import SwiftUI

@MainActor
enum SystemInfoWindow {
    static func open() {
        // Full-size content like the other sidebar windows: without it, the split view's title bar
        // background (and its scroll edge effect) sat a title bar's height too low, over the
        // first row of graphs.
        WindowManager.shared.show(id: "sysinfo", title: "System Information", size: NSSize(width: 940, height: 640),
                                  autosave: "SystemInformation", fullSizeContent: true) {
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
        case thermal = "Thermal"
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
            case .thermal: return "thermometer.medium"
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
                    case .thermal: ThermalPanel(sys: store.system, revision: store.revision)
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
                InfoRow("Model", HardwareInfo.current.productName.map { "\($0) (\(m.modelIdentifier))" } ?? m.modelIdentifier)
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
    static let performanceColor = Color.green
    static let efficiencyColor = Color.cyan

    private func coreLegend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text("\(name) cores").font(.callout).foregroundStyle(.secondary)
        }
    }

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
            let m = MachineInfo.current
            let efficiency = m.coreTypes.map { $0.hasPrefix("E") }
            HStack(spacing: 14) {
                Toggle("Show one graph per CPU", isOn: $perCore).toggleStyle(.checkbox)
                // Only Macs with both kinds of core need telling which graph is which.
                if perCore, efficiency.contains(true), efficiency.contains(false) {
                    Spacer()
                    coreLegend("Performance", Self.performanceColor)
                    coreLegend("Efficiency", Self.efficiencyColor)
                }
            }
            if perCore {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(6, max(2, sys.perCore.count / 2))), spacing: 6) {
                    ForEach(Array(sys.perCore.enumerated()), id: \.offset) { i, h in
                        let kind = m.coreTypes.indices.contains(i) ? " (\(m.coreTypes[i].prefix(1)))" : ""
                        let isEfficiency = efficiency.indices.contains(i) && efficiency[i]
                        GraphView(series: [GraphSeries(values: h.ordered, color: isEfficiency ? Self.efficiencyColor : Self.performanceColor)],
                                  maxValue: 100,
                                  title: "CPU \(i)\(kind)", valueText: percent(h.last), formatter: { String(format: "%.0f%%", $0) })
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
                        if let frequency = PowerMetricsMonitor.shared.frequencySummary {
                            InfoRow("Frequency", frequency)
                        }
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
            ProcessorBox()
        }
        // Frequencies show while powermetrics runs; this starts it only when that needs no password.
        .onAppear { PowerMetricsMonitor.shared.acquire() }
        .onDisappear { PowerMetricsMonitor.shared.release() }
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
                            InfoRow("Installed", Fmt.bytes(MachineInfo.current.memoryBytes))
                            if HardwareInfo.current.usableMemory > 0 {
                                InfoRow("Usable by macOS", Fmt.bytes(HardwareInfo.current.usableMemory))
                            }
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
    /// Read in the background every few seconds: querying volume capacities takes 20-50 ms (more
    /// for network volumes) and ran on the main thread on every refresh.
    @State private var volumes: [Volume] = []

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
                    ForEach(volumes, id: \.path) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(v.name).fontWeight(.medium)
                                Text(v.path).foregroundStyle(.secondary).font(.caption)
                                Spacer()
                                Text((["\(Fmt.bytes(v.total - v.free)) used of \(Fmt.bytes(v.total))", v.format] + v.traits).filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            UsageBar(fraction: Double(v.total - v.free) / Double(max(1, v.total)), color: .blue)
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                volumes = await Task.detached(priority: .utility) { Self.loadVolumes() }.value
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    struct Volume: Sendable {
        var name: String
        var path: String
        var total: UInt64
        var free: UInt64
        var format: String
        /// "Internal", "Encrypted", "Read-only"…
        var traits: [String]
    }

    nonisolated private static func loadVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey,
                                      .volumeIsRemovableKey, .volumeIsEncryptedKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage.map { UInt64($0) } ?? UInt64(v.volumeAvailableCapacity ?? 0)
            var traits: [String] = []
            if v.volumeIsLocal == false {
                traits.append("Network")
            } else if let isInternal = v.volumeIsInternal {
                traits.append(isInternal ? "Internal" : (v.volumeIsRemovable == true ? "Removable" : "External"))
            }
            if v.volumeIsEncrypted == true { traits.append("Encrypted") }
            if v.volumeIsReadOnly == true { traits.append("Read-only") }
            return Volume(name: v.volumeName ?? url.lastPathComponent, path: url.path, total: UInt64(total),
                          free: min(free, UInt64(total)), format: v.volumeLocalizedFormatDescription ?? "", traits: traits)
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
            SectionBox(title: "Addresses") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Interface").bold()
                        Text("IP addresses").bold()
                        Text("Hardware address").bold()
                        Text("MTU").bold()
                        Text("Link speed").bold()
                    }
                    ForEach(addressed, id: \.name) { a in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(a.name)
                            Text((a.ipv4 + a.ipv6).joined(separator: "\n")).textSelection(.enabled)
                            Text(a.hardwareAddress ?? "").monospaced().textSelection(.enabled)
                            Text(a.mtu.map(String.init) ?? "").monospacedDigit()
                            // The counters carry the speed as 64 bits; getifaddrs has 32, which
                            // tops out near 4.3 Gbit/s (10GbE, Thunderbolt bridges).
                            let counted = sys.last?.interfaces.first { $0.name == a.name }.flatMap { $0.baudrate > 0 ? $0.baudrate : nil }
                            Text((counted ?? a.linkSpeed).map(Self.linkSpeed) ?? "").monospacedDigit()
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                addresses = await Task.detached(priority: .utility) { InterfaceAddresses.read() }.value
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Re-read every few seconds: addresses change as networks come and go.
    @State private var addresses: [String: InterfaceAddresses] = [:]

    /// Interfaces with an IP address, in the order of the traffic table, then the rest by name.
    private var addressed: [InterfaceAddresses] {
        let order = interfaces.map(\.name)
        return addresses.values.filter { !$0.ipv4.isEmpty || !$0.ipv6.isEmpty }.sorted {
            let a = order.firstIndex(of: $0.name) ?? Int.max, b = order.firstIndex(of: $1.name) ?? Int.max
            return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func linkSpeed(_ bitsPerSecond: UInt64) -> String {
        let units: [(Double, String)] = [(1e9, "Gbit/s"), (1e6, "Mbit/s"), (1e3, "kbit/s")]
        let v = Double(bitsPerSecond)
        for (scale, unit) in units where v >= scale {
            let n = v / scale
            return (n == n.rounded() ? String(format: "%.0f", n) : String(format: "%.1f", n)) + " " + unit
        }
        return "\(bitsPerSecond) bit/s"
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
                        if let metal = HardwareInfo.current.gpus.first(where: { $0.name == g.name }) {
                            MetalRows(gpu: metal)
                        }
                    }
                }
            }
            let listed = Set((sys.last?.gpus ?? []).map(\.name))
            ForEach(HardwareInfo.current.gpus.filter { !listed.contains($0.name) }) { metal in
                SectionBox(title: metal.name) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        MetalRows(gpu: metal)
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

/// The processor's core types and caches; see `HardwareInfo`.
struct ProcessorBox: View {
    var body: some View {
        let m = MachineInfo.current
        let hw = HardwareInfo.current
        SectionBox(title: "Processor") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                InfoRow("Name", m.cpuBrand)
                InfoRow("Architecture", hw.architecture)
                InfoRow("Cores", m.physicalCores == m.logicalCores
                    ? "\(m.physicalCores)" : "\(m.physicalCores) (\(m.logicalCores) logical)")
                ForEach(hw.coreTypes) { t in
                    InfoRow("\(t.name) cores", describe(t))
                }
                if hw.coreTypes.isEmpty {
                    InfoRow("L1 cache", "\(Self.cacheSize(hw.l1InstructionCache)) instruction, \(Self.cacheSize(hw.l1DataCache)) data")
                    InfoRow("L2 cache", Self.cacheSize(hw.l2Cache))
                    if hw.l3Cache > 0 {
                        InfoRow("L3 cache", Self.cacheSize(hw.l3Cache))
                    }
                }
                InfoRow("Cache line", "\(hw.cacheLineSize) bytes")
            }
        }
    }

    private func describe(_ t: HardwareInfo.CoreType) -> String {
        var parts = ["\(t.physicalCores)" + (t.logicalCores != t.physicalCores ? " (\(t.logicalCores) logical)" : "")]
        if t.l1InstructionCache > 0 {
            parts.append("L1 \(Self.cacheSize(t.l1InstructionCache)) instruction + \(Self.cacheSize(t.l1DataCache)) data per core")
        }
        if t.l2Cache > 0 {
            let shared = t.coresPerL2 > 1 ? " shared by each \(t.coresPerL2) cores" : " per core"
            parts.append("L2 \(Self.cacheSize(t.l2Cache))\(shared)")
        }
        return parts.joined(separator: " · ")
    }

    /// Cache sizes are powers of two: "192 KB", "16 MB".
    static func cacheSize(_ bytes: Int) -> String {
        if bytes >= 1 << 20, bytes % (1 << 20) == 0 { return "\(bytes >> 20) MB" }
        if bytes >= 1 << 10, bytes % (1 << 10) == 0 { return "\(bytes >> 10) KB" }
        return Fmt.bytes(UInt64(max(0, bytes)))
    }
}

/// What a GPU supports, from Metal; see `HardwareInfo.GPU`.
struct MetalRows: View {
    let gpu: HardwareInfo.GPU

    var body: some View {
        if !gpu.location.isEmpty {
            InfoRow("Location", gpu.location)
        }
        InfoRow("Memory", gpu.unifiedMemory ? "Unified (shared with the CPU)" : "Dedicated")
        InfoRow("Recommended working set", Fmt.bytes(gpu.recommendedWorkingSet))
        InfoRow("Largest buffer", Fmt.bytes(UInt64(max(0, gpu.maxBufferLength))))
        InfoRow("Metal support", gpu.families.joined(separator: ", "))
        InfoRow("Hardware ray tracing", gpu.raytracing ? "Yes" : "No")
        InfoRow("Threads per threadgroup", "\(gpu.maxThreadsPerThreadgroup)")
        InfoRow("Threadgroup memory", Fmt.bytes(UInt64(max(0, gpu.maxThreadgroupMemory))))
        let traits = [gpu.lowPower ? "Low power" : nil, gpu.headless ? "Headless" : nil, gpu.removable ? "Removable" : nil].compactMap { $0 }
        if !traits.isEmpty {
            InfoRow("Type", traits.joined(separator: ", "))
        }
    }
}

/// Processes whose power assertions keep the Mac or its display awake.
struct SleepPreventersBox: View {
    var body: some View {
        SectionBox(title: "Keeping the Mac awake") {
            let list = processes
            if list.isEmpty {
                Text("No process is preventing sleep.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Process")
                        Text("Keeps on")
                        Text("Assertion")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(list, id: \.key) { p in
                        let a = p.assertions.first { $0.sleepPrevention == p.sleepPrevention }
                        GridRow {
                            Button { PropertiesWindow.open(p, tab: .power) } label: {
                                Label {
                                    Text("\(p.displayName)  \(Text(String(p.pid)).foregroundStyle(.secondary))")
                                } icon: {
                                    Image(nsImage: ProcessIcons.icon(for: p.record))
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Show the process's power assertions")
                            Text(p.sleepPrevention?.title ?? "")
                            Text(a.map { $0.name.isEmpty ? $0.type : $0.name } ?? "")
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var processes: [ProcessItem] {
        ProcessStore.shared.items.values
            .filter { !$0.isRemoved && $0.sleepPrevention != nil }
            .sorted { ($0.sleepPrevention!.rawValue, $1.pid) > ($1.sleepPrevention!.rawValue, $0.pid) }
    }
}

/// Thermal state, thermal pressure, CPU cluster frequencies and measured power.
struct ThermalPanel: View {
    let sys: SystemMonitor
    let revision: Int
    @ObservedObject private var metrics = PowerMetricsMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SectionBox(title: "Thermal state") {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(sys.thermalState.title, systemImage: "thermometer.medium")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(sys.thermalState.color)
                        Text(sys.thermalState.explanation).foregroundStyle(.secondary)
                    }
                }
                SectionBox(title: "Thermal pressure") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let pressure = metrics.latest?.thermalPressure {
                            Text(pressure).font(.title3.weight(.semibold))
                                .foregroundStyle(pressure == "Nominal" ? Color.green : pressure == "Moderate" ? .yellow : .red)
                            Text("How hard the system is working to stay cool, from powermetrics.").foregroundStyle(.secondary)
                        } else {
                            Text(metrics.starting ? "Starting powermetrics…" : "Not measured").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            GraphView(series: [GraphSeries(values: sys.thermalLevel.ordered, color: .orange, label: "Thermal state")],
                      maxValue: 3, title: "Thermal state", valueText: sys.thermalState.title,
                      formatter: { ["Nominal", "Fair", "Serious", "Critical"][max(0, min(3, Int($0.rounded())))] })
                .frame(height: 90)
            if metrics.running || metrics.latest != nil {
                measured
            } else {
                powermetricsPrompt
            }
        }
        .onAppear { metrics.acquire() }
        .onDisappear { metrics.release() }
    }

    @ViewBuilder
    private var measured: some View {
        let names = metrics.clusterNames
        if !names.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(3, names.count)), spacing: 8) {
                ForEach(names, id: \.self) { name in
                    let h = metrics.clusterFrequency[name] ?? History()
                    let active = metrics.latest?.clusters.first { $0.name == name }?.activeRatio ?? 0
                    GraphView(series: [GraphSeries(values: h.ordered, color: name.hasPrefix("E") ? .teal : .blue, label: name)],
                              maxValue: max(1000, h.maxValue), title: name.replacingOccurrences(of: "-Cluster", with: " cluster"),
                              valueText: String(format: "%.2f GHz · %.0f%% active", h.last / 1000, active * 100),
                              formatter: { String(format: "%.0f MHz", $0) })
                        .frame(height: 110)
                }
            }
        }
        GraphView(series: [GraphSeries(values: metrics.cpuPower.ordered, color: .green, label: "CPU"),
                           GraphSeries(values: metrics.gpuPower.ordered, color: .indigo, label: "GPU"),
                           GraphSeries(values: metrics.anePower.ordered, color: .pink, label: "Neural Engine")],
                  title: "Measured power",
                  valueText: "CPU \(Fmt.watts(metrics.latest?.cpuPower ?? 0).ifEmpty("0 W")) · GPU \(Fmt.watts(metrics.latest?.gpuPower ?? 0).ifEmpty("0 W")) · ANE \(Fmt.watts(metrics.latest?.anePower ?? 0).ifEmpty("0 W"))",
                  formatter: { Fmt.watts($0).ifEmpty("0 W") }, stacked: true)
            .frame(height: 150)
        GraphView(series: [GraphSeries(values: metrics.gpuFrequency.ordered, color: .indigo, label: "GPU")],
                  title: "GPU frequency", valueText: String(format: "%.0f MHz", metrics.gpuFrequency.last),
                  formatter: { String(format: "%.0f MHz", $0) })
            .frame(height: 90)
        if let error = metrics.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
        }
    }

    private var powermetricsPrompt: some View {
        SectionBox(title: "Frequency and measured power") {
            VStack(alignment: .leading, spacing: 8) {
                Text("CPU cluster frequencies, thermal pressure and the power the CPU, GPU and Neural Engine draw come from powermetrics, which needs administrator rights.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = metrics.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Button(metrics.starting ? "Starting…" : "Show Frequency and Power…") { metrics.start(prompt: true) }
                    .disabled(metrics.starting)
                    .help("Run powermetrics as root while this section is open (asks for an administrator password if needed)")
            }
        }
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
            if let s = PowerMetricsMonitor.shared.latest {
                SectionBox(title: "Measured power (powermetrics)") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("CPU", Fmt.watts(s.cpuPower ?? 0).ifEmpty("0 W"))
                        InfoRow("GPU", Fmt.watts(s.gpuPower ?? 0).ifEmpty("0 W"))
                        InfoRow("Neural Engine", Fmt.watts(s.anePower ?? 0).ifEmpty("0 W"))
                        InfoRow("Combined", Fmt.watts(s.combinedPower ?? 0).ifEmpty("0 W"))
                    }
                }
            }
            SleepPreventersBox()
            if let b = sys.last?.battery, b.present {
                SectionBox(title: "Battery") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Charge", String(format: "%.0f%%", b.percent))
                        InfoRow("Power source", b.onAC ? (b.charging ? "Power adapter (charging)" : "Power adapter") : "Battery")
                        // While charging the estimate is the time until full. On the adapter and
                        // not charging (full, or held by charge limiting) there is none to wait for.
                        let estimated = b.timeRemainingMinutes > 0 && b.timeRemainingMinutes < 65535
                        if estimated || !b.onAC || b.charging {
                            InfoRow(b.charging ? "Time until full" : "Time remaining",
                                    estimated ? "\(b.timeRemainingMinutes / 60)h \(b.timeRemainingMinutes % 60)m" : "Calculating…")
                        }
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
        .onAppear { PowerMetricsMonitor.shared.acquire() }
        .onDisappear { PowerMetricsMonitor.shared.release() }
    }
}
