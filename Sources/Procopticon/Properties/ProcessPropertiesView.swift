import AppKit
import ProcopticonCore
import SwiftUI

struct ProcessPropertiesView: View {
    let key: ProcessKey
    @ObservedObject private var store = ProcessStore.shared
    @State private var tab: PropertyTab
    /// Height last used for the table tabs, restored when switching back to one.
    @AppStorage("propertiesTableHeight") private var tableHeight: Double = 520
    /// Width the window was last resized to; new properties windows open at it.
    @AppStorage(PropertiesWindow.widthKey) private var windowWidth: Double = PropertiesWindow.defaultWidth
    /// Last known state, kept so the window stays useful after the process exits.
    @State private var snapshot: ProcessItem?
    @State private var window: NSWindow?
    @State private var detailHeight: CGFloat = 0
    @State private var page: PageFit?
    /// Set when the tab changes; the window fits the new tab while its content settles.
    @State private var fitUntil: Date?
    /// Height an animated fit is heading to, so fits requested meanwhile don't restart it.
    @State private var fitTarget: CGFloat?
    @State private var fittedOnce = false

    enum PropertyTab: String, SidebarPage {
        case general = "General"
        case statistics = "Statistics"
        case performance = "Performance"
        case power = "Power"
        case threads = "Threads"
        case modules = "Modules"
        case memory = "Memory"
        case arguments = "Arguments"
        case environment = "Environment"
        case files = "Files"
        case network = "Network"
        case log = "Log"
        case crashes = "Crash Reports"
        case security = "Security"
        case service = "Service"
        var id: String { rawValue }
        var title: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "info.circle"
            case .statistics: return "chart.bar"
            case .performance: return "waveform.path.ecg"
            case .power: return "bolt"
            case .threads: return "square.stack.3d.up"
            case .modules: return "shippingbox"
            case .memory: return "memorychip"
            case .arguments: return "list.number"
            case .environment: return "terminal"
            case .files: return "doc.on.doc"
            case .network: return "network"
            case .log: return "text.alignleft"
            case .crashes: return "exclamationmark.triangle"
            case .security: return "lock.shield"
            case .service: return "gearshape.2"
            }
        }

        /// How the window sizes itself for this tab.
        var fit: Fit {
            switch self {
            case .general, .statistics, .security, .service: return .content
            case .performance: return .height(700)
            case .threads, .modules, .memory, .arguments, .environment, .files, .network, .power, .log, .crashes: return .table
            }
        }
    }

    enum Fit {
        /// As tall as the page's content (up to the screen height).
        case content
        /// A fixed height for the tab's content area.
        case height(CGFloat)
        /// The height last used for a table tab.
        case table
    }

    static let minHeight: CGFloat = 530

    init(key: ProcessKey, tab: PropertyTab = .general) {
        self.key = key
        _tab = State(initialValue: tab)
    }

    var item: ProcessItem? { store.item(key) ?? snapshot }

    var body: some View {
        Group {
            if let item {
                SidebarPagesView(selection: $tab) { tab in
                    VStack(spacing: 0) {
                        if item.isRemoved || store.item(key) == nil {
                            Label("This process has exited.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            Divider()
                        }
                        content(item, tab)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentAreaResized($0) }
                    }
                }
                .onAppear {
                    snapshot = item
                    startFitting()
                }
            } else {
                ContentUnavailableView("Process not found", systemImage: "questionmark.app", description: Text("PID \(key.pid) is no longer running."))
            }
        }
        // Tall enough for every sidebar item.
        .frame(minWidth: 680, minHeight: Self.minHeight)
        // Only the user changes the width (fitting changes the height), so remember it.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width >= 680 {
                windowWidth = Double(width)
            }
        }
        .background(WindowAccessor { window = $0; fitWindow() })
        .onPreferenceChange(PageFitKey.self) { value in
            page = value
            fitWindow()
        }
        .onChange(of: tab) { startFitting() }
    }

    @ViewBuilder
    private func content(_ item: ProcessItem, _ tab: PropertyTab) -> some View {
        switch tab {
        case .general: GeneralTab(item: item, revision: store.revision)
        case .statistics: StatisticsTab(item: item, revision: store.revision)
        case .performance: PerformanceTab(item: item, revision: store.revision)
        case .power: PowerTab(item: item, revision: store.revision)
        case .threads: ThreadsTab(item: item)
        case .modules: ModulesTab(item: item)
        case .memory: MemoryTab(item: item)
        case .arguments: ArgumentsTab(item: item)
        case .environment: EnvironmentTab(item: item)
        case .files: FilesTab(item: item)
        case .network: ProcessNetworkTab(item: item)
        case .log: ProcessLogTab(item: item)
        case .crashes: ProcessReportsTab(item: item)
        case .security: SecurityTab(item: item)
        case .service: ServiceTab(item: item)
        }
    }

    // MARK: Fitting the window to the tab

    private func startFitting() {
        // Content that loads asynchronously (signatures, working directory) can grow the page
        // shortly after the switch; keep fitting until it settles, then leave the size alone.
        fitUntil = Date().addingTimeInterval(1.5)
        DispatchQueue.main.async { fitWindow() }
    }

    private var isFitting: Bool {
        fitUntil.map { Date() < $0 } ?? false
    }

    private func contentAreaResized(_ height: CGFloat) {
        detailHeight = height
        // Remember the size the user picks for tables.
        if case .table = tab.fit, !isFitting, height > 0 {
            tableHeight = Double(height)
        }
    }

    private func fitWindow() {
        guard let window, isFitting, detailHeight > 0 else { return }
        let desired: CGFloat
        switch tab.fit {
        case .content:
            guard let page, page.tab == tab.rawValue else { return }
            desired = page.height
        case .height(let h):
            desired = h
        case .table:
            desired = CGFloat(tableHeight)
        }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = window.frame
        let height = min(max(frame.height + desired - detailHeight, window.minSize.height, Self.minHeight), visible.height)
        guard abs(height - frame.height) > 1, fitTarget.map({ abs($0 - height) > 1 }) ?? true else { return }
        // Keep the top edge where it is, and the window on screen.
        frame.origin.y = max(frame.maxY - height, visible.minY)
        frame.size.height = height
        // Not setFrame(_:display:animate:), which blocks until the animation ends and lays the
        // whole page out again on every frame: opening the window took half a second. The first
        // fit (as the window opens) is immediate; later ones animate without blocking.
        guard fittedOnce, window.isVisible else {
            fittedOnce = true
            window.setFrame(frame, display: true)
            return
        }
        fitTarget = height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            fitTarget = nil
        }
    }
}

/// Height of a form-like property page's content, so the window can fit it.
struct PageFit: Equatable {
    var tab: String
    var height: CGFloat
}

struct PageFitKey: PreferenceKey {
    static let defaultValue: PageFit? = nil
    static func reduce(value: inout PageFit?, nextValue: () -> PageFit?) {
        value = nextValue() ?? value
    }
}

/// Scrolling page for the form-like property tabs. It reports its content height so the window can
/// grow or shrink to fit when the tab is selected.
struct PropertyPage<Content: View>: View {
    let tab: ProcessPropertiesView.PropertyTab
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PageFitKey.self, value: PageFit(tab: tab.rawValue, height: proxy.size.height))
                    }
                }
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
                .help("Authorize once (administrator password) to see every process in full")
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
            // Both the request and the parsing (which can be heavy, e.g. vmmap output) run off-main.
            let (response, extracted) = await Task.detached { () -> (PrivilegedResponse, T?) in
                let r = Elevation.shared.perform(request)
                return (r, r.error == nil ? extract(r) : nil)
            }.value
            if let e = response.error {
                error = e
            } else if let v = extracted {
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
        PropertyPage(tab: .general) {
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
                        InfoRow("Command line", (r.commandLine ?? "(unavailable — requires elevation)")
                                    + (r.argumentsOverwritten ? "  (the process overwrote its arguments when it set its title)" : ""))
                        if let title = r.title {
                            InfoRow("Process title", title)
                        }
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
                            .help("Show the executable in Finder")
                        Button("Inspect Executable…") { if let p = r.path { InspectorWindow.open(path: p) } }.disabled(r.path == nil)
                            .help("Open the executable in the inspector: Mach-O header, libraries, symbols and signature")
                        Button("Copy Command Line") { ProcessActions.copy(r.commandLine ?? "") }.disabled(r.commandLine == nil)
                            .help("Copy the command line, shell-quoted, to the clipboard")
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
                                        .help("Select the parent process in the process list")
                                }
                            }
                        }
                        if let resp = r.responsiblePid, resp != r.pid {
                            GridRow {
                                Text("Responsible").foregroundStyle(.secondary)
                                HStack {
                                    Text(processName(resp)).textSelection(.enabled)
                                    Button("Show") { ProcessSelection.shared.reveal(pid: resp) }.controlSize(.small)
                                        .help("Select the responsible process in the process list")
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
                        .help("Ask the process to quit (SIGTERM)")
                    if r.isStopped {
                        Button("Resume") { ProcessActions.resume([item]) }
                            .help("Let the suspended process run again (SIGCONT)")
                    } else {
                        Button("Suspend") { ProcessActions.suspend([item]) }
                            .help("Pause the process until it's resumed (SIGSTOP)")
                    }
                    Button("Sample…") { ProcessActions.sample(item) }
                        .help("Record what the process's threads are doing for a few seconds (sample)")
                    Spacer()
                }
            }
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
        PropertyPage(tab: .statistics) {
            if s == nil {
                AccessDeniedView(message: "Statistics for processes owned by other users require administrator privileges.") {}
                    .frame(height: 260)
            }
            // Two columns when there's room, one when the window is narrow.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
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
                SectionBox(title: "Network") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        let n = item.network
                        InfoRow("Received", n.map { Fmt.bytes($0.bytesIn) } ?? "")
                        InfoRow("Sent", n.map { Fmt.bytes($0.bytesOut) } ?? "")
                        InfoRow("Packets received", n.map { Fmt.count($0.packetsIn) } ?? "")
                        InfoRow("Packets sent", n.map { Fmt.count($0.packetsOut) } ?? "")
                        InfoRow("Receive rate", Fmt.rate(item.netInRate))
                        InfoRow("Send rate", Fmt.rate(item.netOutRate))
                    }
                }
                SectionBox(title: "GPU") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        InfoRow("Usage", (Fmt.percent(item.gpu).isEmpty ? "0" : Fmt.percent(item.gpu)) + "%")
                        InfoRow("GPU time", Fmt.duration(nanoseconds: item.gpuTimeNs))
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
            GraphView(series: [GraphSeries(values: item.gpuHistory.ordered, color: .indigo, label: "GPU")],
                      maxValue: 100, capacity: item.gpuHistory.capacity, title: "GPU",
                      valueText: (Fmt.percent(item.gpu).isEmpty ? "0" : Fmt.percent(item.gpu)) + "%  (GPU time \(Fmt.duration(nanoseconds: item.gpuTimeNs)))",
                      formatter: { String(format: "%.2f%%", $0) })
        }
        .padding()
    }
}
