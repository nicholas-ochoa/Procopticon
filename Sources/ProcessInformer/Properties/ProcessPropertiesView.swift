import AppKit
import InformerCore
import SwiftUI

struct ProcessPropertiesView: View {
    let key: ProcessKey
    @ObservedObject private var store = ProcessStore.shared
    @State private var tab: PropertyTab = .general
    /// Last known state, kept so the window stays useful after the process exits.
    @State private var snapshot: ProcessItem?

    enum PropertyTab: String, CaseIterable, Identifiable {
        case general = "General"
        case statistics = "Statistics"
        case performance = "Performance"
        case threads = "Threads"
        case modules = "Modules"
        case memory = "Memory"
        case environment = "Environment"
        case files = "Files"
        case network = "Network"
        case security = "Security"
        case service = "Service"
        var id: String { rawValue }
    }

    var item: ProcessItem? { store.item(key) ?? snapshot }

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(PropertyTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    if item.isRemoved || store.item(key) == nil {
                        Label("This process has exited.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .padding(.bottom, 4)
                    }
                    Divider()
                    content(item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear { snapshot = item }
            } else {
                ContentUnavailableView("Process not found", systemImage: "questionmark.app", description: Text("PID \(key.pid) is no longer running."))
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    @ViewBuilder
    private func content(_ item: ProcessItem) -> some View {
        switch tab {
        case .general: GeneralTab(item: item, revision: store.revision)
        case .statistics: StatisticsTab(item: item, revision: store.revision)
        case .performance: PerformanceTab(item: item, revision: store.revision)
        case .threads: ThreadsTab(item: item)
        case .modules: ModulesTab(item: item)
        case .memory: MemoryTab(item: item)
        case .environment: EnvironmentTab(item: item)
        case .files: FilesTab(item: item)
        case .network: ProcessNetworkTab(item: item)
        case .security: SecurityTab(item: item)
        case .service: ServiceTab(item: item)
        }
    }
}

/// Banner shown when data requires elevation, with a button to authorize.
struct AccessDeniedView: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Access denied").font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            if Elevation.shared.mode == .standard {
                Button("Show Details for All Processes…") {
                    Task {
                        do {
                            try await Elevation.shared.startHelper()
                            retry()
                        } catch let e as PrivilegedError where e == .cancelled {
                        } catch {
                            Alerts.error("Unable to elevate", error.localizedDescription)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Loads data through the privileged broker without prompting; exposes permission failures.
@MainActor
final class PrivilegedLoader<T>: ObservableObject {
    @Published var value: T?
    @Published var error: PrivilegedError?
    @Published var loading = false

    func load(_ request: PrivilegedRequest, extract: @escaping (PrivilegedResponse) -> T?) {
        loading = true
        Task {
            let response = await Task.detached { Elevation.shared.perform(request) }.value
            if let e = response.error {
                error = e
            } else if let v = extract(response) {
                value = v
                error = nil
            } else {
                error = PrivilegedError(code: EPERM, message: "Access denied")
            }
            loading = false
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    let item: ProcessItem
    let revision: Int
    @State private var cwd: String = ""
    @State private var runtimeValidation: String = ""

    var body: some View {
        let r = item.record
        let bundle = item.bundleInfo
        let signing = item.signing
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: bigIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bundle?.displayName ?? item.name).font(.title2.weight(.semibold))
                        Text([bundle?.versionString ?? "", signing?.organization ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        if let copyright = bundle?.copyright {
                            Text(copyright).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                SectionBox(title: "Image") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        InfoRow("Path", r.path ?? "")
                        InfoRow("Command line", r.commandLine ?? "(unavailable — requires elevation)")
                        InfoRow("Working directory", cwd)
                        InfoRow("Bundle", bundle?.bundlePath ?? "")
                        InfoRow("Bundle identifier", bundle?.bundleIdentifier ?? "")
                        InfoRow("Architecture", r.architecture)
                        if let size = bundle?.fileSize {
                            InfoRow("File size", Fmt.bytes(size))
                        }
                        if let m = bundle?.fileModified {
                            InfoRow("Modified", m.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                    HStack {
                        Button("Reveal in Finder") { ProcessActions.revealInFinder(item) }.disabled(r.path == nil)
                        Button("Inspect Executable…") { if let p = r.path { InspectorWindow.open(path: p) } }.disabled(r.path == nil)
                        Button("Copy Command Line") { ProcessActions.copy(r.commandLine ?? "") }.disabled(r.commandLine == nil)
                    }
                    .padding(.top, 6)
                }
                SectionBox(title: "Process") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        InfoRow("PID", "\(r.pid)")
                        InfoRow("Started", "\(Fmt.date(r.startTime))  (\(Fmt.relative(seconds: Date().timeIntervalSince1970 - r.startTime)) ago)")
                        GridRow {
                            Text("Parent").foregroundStyle(.secondary)
                            HStack {
                                Text(parentDescription).textSelection(.enabled)
                                if ProcessStore.shared.item(pid: r.ppid) != nil, r.ppid != r.pid {
                                    Button("Show") { ProcessSelection.shared.reveal(pid: r.ppid) }.controlSize(.small)
                                }
                            }
                        }
                        if let resp = r.responsiblePid, resp != r.pid {
                            GridRow {
                                Text("Responsible").foregroundStyle(.secondary)
                                HStack {
                                    Text(processName(resp)).textSelection(.enabled)
                                    Button("Show") { ProcessSelection.shared.reveal(pid: resp) }.controlSize(.small)
                                }
                            }
                        }
                        InfoRow("User", "\(UserNames.name(r.uid)) (\(r.uid))\(r.ruid != r.uid ? ", real: \(UserNames.name(r.ruid)) (\(r.ruid))" : "")")
                        InfoRow("Group", "\(UserNames.group(r.rgid)) (\(r.rgid))")
                        InfoRow("State", r.stateDescription + (r.isTraced ? ", traced" : ""))
                        InfoRow("Process group / TTY", "\(r.pgid)\(r.ttyName.map { " · \($0)" } ?? "")")
                        InfoRow("Sandbox", r.sandboxed == true ? "Sandboxed" : (r.sandboxed == false ? "Not sandboxed" : "Unknown"))
                    }
                }
                SectionBox(title: "Code Signature") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        InfoRow("Status", signing?.verificationSummary ?? "Checking…")
                        InfoRow("Signer", signing?.signer ?? "")
                        InfoRow("Identifier", signing?.identifier ?? "")
                        InfoRow("Team ID", signing?.teamIdentifier ?? "")
                        InfoRow("Running code", runtimeValidation)
                        if let flags = r.csFlags {
                            InfoRow("Runtime flags", CodeSigningFlags.describe(flags).joined(separator: ", "))
                        }
                    }
                }
                HStack {
                    Button("Terminate") { ProcessActions.terminate([item]) }
                    if r.isStopped {
                        Button("Resume") { ProcessActions.resume([item]) }
                    } else {
                        Button("Suspend") { ProcessActions.suspend([item]) }
                    }
                    Button("Sample…") { ProcessActions.sample(item) }
                    Spacer()
                }
            }
            .padding()
        }
        .task(id: item.key) {
            let pid = item.pid
            let response = await Task.detached { Elevation.shared.perform(.workingDirectory(pid: pid)) }.value
            if case .text(let s) = response {
                cwd = s
            } else {
                cwd = response.error.map { "(\($0.isPermissionDenied ? "requires elevation" : $0.message))" } ?? ""
            }
            let v = await Task.detached { CodeSigning.validateRunning(pid: pid) }.value
            runtimeValidation = v.valid ? "Valid" : v.detail
        }
    }

    private var bigIcon: NSImage {
        guard let path = item.record.path else { return ProcessIcons.executable }
        if let bundle = BundleInfoCache.enclosingBundlePath(path) {
            return NSWorkspace.shared.icon(forFile: bundle)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    private var parentDescription: String {
        processName(item.record.ppid)
    }

    private func processName(_ pid: Int32) -> String {
        if let p = ProcessStore.shared.item(pid: pid) {
            return "\(p.name) (\(pid))"
        }
        return "Non-existent process (\(pid))"
    }
}

// MARK: - Statistics

struct StatisticsTab: View {
    let item: ProcessItem
    let revision: Int

    var body: some View {
        let s = item.stats
        ScrollView {
            if s == nil {
                AccessDeniedView(message: "Statistics for processes owned by other users require administrator privileges.") {}
                    .frame(height: 260)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 14) {
                SectionBox(title: "CPU") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Usage", Fmt.percent(item.cpu) + "%")
                        InfoRow("Base priority", s.map { "\($0.priority)" } ?? "")
                        InfoRow("Nice", "\(item.record.nice)")
                        InfoRow("User time", s.map { Fmt.duration(nanoseconds: $0.userTimeNs) } ?? "")
                        InfoRow("Kernel time", s.map { Fmt.duration(nanoseconds: $0.systemTimeNs) } ?? "")
                        InfoRow("Total time", s.map { Fmt.duration(nanoseconds: $0.totalTimeNs) } ?? "")
                        InfoRow("P-core time", s.map { Fmt.duration(nanoseconds: $0.pTimeNs) } ?? "")
                        InfoRow("Runnable time", s.map { Fmt.duration(nanoseconds: $0.runnableTimeNs) } ?? "")
                        InfoRow("Cycles", s.map { Fmt.count($0.cycles) } ?? "")
                        InfoRow("Instructions", s.map { Fmt.count($0.instructions) } ?? "")
                        InfoRow("Context switches", s.map { Fmt.count(Int($0.contextSwitches)) } ?? "")
                        InfoRow("Threads", s.map { "\($0.threadCount) (\($0.runningThreads) running)" } ?? "")
                    }
                }
                SectionBox(title: "Memory") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Footprint", s.map { Fmt.bytes($0.physFootprint) } ?? "")
                        InfoRow("Peak footprint", s.map { Fmt.bytes($0.lifetimeMaxFootprint) } ?? "")
                        InfoRow("Resident", s.map { Fmt.bytes($0.residentSize) } ?? "")
                        InfoRow("Virtual", s.map { Fmt.bytes($0.virtualSize) } ?? "")
                        InfoRow("Wired", s.map { Fmt.bytes($0.wiredSize) } ?? "")
                        InfoRow("Neural Engine", s.map { Fmt.bytes($0.neuralFootprint) } ?? "")
                        InfoRow("Page faults", s.map { Fmt.count(Int($0.faults)) } ?? "")
                        InfoRow("Page-ins", s.map { Fmt.count(Int($0.pageins)) } ?? "")
                        InfoRow("Copy-on-write faults", s.map { Fmt.count(Int($0.cowFaults)) } ?? "")
                    }
                }
                SectionBox(title: "I/O") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Disk read", s.map { Fmt.bytes($0.diskBytesRead) } ?? "")
                        InfoRow("Disk written", s.map { Fmt.bytes($0.diskBytesWritten) } ?? "")
                        InfoRow("Logical writes", s.map { Fmt.bytes($0.logicalWrites) } ?? "")
                        InfoRow("Read rate", Fmt.rate(item.diskReadRate))
                        InfoRow("Write rate", Fmt.rate(item.diskWriteRate))
                        InfoRow("Open files", item.record.fdCount.map { "\($0)" } ?? "")
                    }
                }
                SectionBox(title: "Other") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Mach messages sent", s.map { Fmt.count(Int($0.messagesSent)) } ?? "")
                        InfoRow("Mach messages received", s.map { Fmt.count(Int($0.messagesReceived)) } ?? "")
                        InfoRow("Mach system calls", s.map { Fmt.count(Int($0.syscallsMach)) } ?? "")
                        InfoRow("BSD system calls", s.map { Fmt.count(Int($0.syscallsUnix)) } ?? "")
                        InfoRow("Idle wake-ups", s.map { Fmt.count($0.idleWakeups) } ?? "")
                        InfoRow("Interrupt wake-ups", s.map { Fmt.count($0.interruptWakeups) } ?? "")
                        InfoRow("Energy", s.map { String(format: "%.2f J", Double($0.energyNj) / 1e9) } ?? "")
                        InfoRow("Power", Fmt.watts(item.power))
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Performance

struct PerformanceTab: View {
    let item: ProcessItem
    let revision: Int

    var body: some View {
        VStack(spacing: 10) {
            GraphView(series: [GraphSeries(values: item.cpuHistory.ordered, color: .green, label: "CPU")],
                      maxValue: 100, capacity: item.cpuHistory.capacity, title: "CPU",
                      valueText: Fmt.percent(item.cpu) + "% (user \(Fmt.percent(item.cpuUser)), kernel \(Fmt.percent(item.cpuKernel)))",
                      formatter: { String(format: "%.2f%%", $0) })
            GraphView(series: [GraphSeries(values: item.memoryHistory.ordered, color: .orange, label: "Footprint")],
                      capacity: item.memoryHistory.capacity, title: "Memory",
                      valueText: Fmt.bytes(item.stats?.physFootprint ?? 0), formatter: { Fmt.bytes($0) })
            GraphView(series: [GraphSeries(values: item.ioHistory.ordered, color: .blue, label: "Disk")],
                      capacity: item.ioHistory.capacity, title: "Disk I/O",
                      valueText: "R \(Fmt.rate(item.diskReadRate)) · W \(Fmt.rate(item.diskWriteRate))", formatter: { Fmt.rate($0) })
        }
        .padding()
    }
}
