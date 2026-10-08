import Combine
import Darwin
import Foundation

/// Immutable snapshot of one process, published to the UI after each update.
///
/// Snapshots are built on the store's background queue and never mutated once published, so the
/// main thread can read them freely while the next update is being computed.
public final class ProcessItem: Identifiable {
    public let key: ProcessKey
    public var id: ProcessKey { key }
    public let record: ProcessRecord
    /// Tree links of this snapshot (set before publication). The tree parent can be the
    /// responsible process rather than `record.ppid` (see `ProcessStore.treeParent`).
    public internal(set) weak var parent: ProcessItem?
    /// Children currently displayed (filtered, sorted).
    public internal(set) var children: [ProcessItem] = []

    public let cpu: Double
    public let cpuUser: Double
    public let cpuKernel: Double
    public let diskReadRate: Double
    public let diskWriteRate: Double
    public let memoryDelta: Int64
    public let faultsDelta: Int64
    public let pageinsDelta: Int64
    public let contextSwitchesDelta: Int64
    public let syscallsDelta: Int64
    public let wakeupsDelta: Int64
    public let cyclesDelta: UInt64
    public let instructionsDelta: UInt64
    public let messagesDelta: Int64
    public let power: Double
    /// GPU usage (percent of the GPU's time) over the last interval.
    public let gpu: Double
    /// GPU time used by the process's GPU connections while Procopticon watched, plus what they had
    /// used when first seen.
    public let gpuTimeNs: UInt64
    /// Network traffic of the process's sockets (nil if it has had none while watched); see
    /// `ProcessState.updateNetwork`.
    public let network: NetworkCounters?
    public let netInRate: Double
    public let netOutRate: Double
    public let cpuHistory: History
    public let memoryHistory: History
    public let ioHistory: History
    public let gpuHistory: History
    /// Receive + send rate.
    public let netHistory: History
    public let firstSeen: Date
    public let removedAt: Date?
    public let isInitial: Bool
    /// Cached so hot paths (sorting, cell drawing) don't repeat lookups.
    public let userName: String
    public let bundleInfo: ExecutableBundleInfo?

    init(_ s: ProcessState) {
        key = s.record.key
        record = s.record
        cpu = s.cpu
        cpuUser = s.cpuUser
        cpuKernel = s.cpuKernel
        diskReadRate = s.diskReadRate
        diskWriteRate = s.diskWriteRate
        memoryDelta = s.memoryDelta
        faultsDelta = s.faultsDelta
        pageinsDelta = s.pageinsDelta
        contextSwitchesDelta = s.contextSwitchesDelta
        syscallsDelta = s.syscallsDelta
        wakeupsDelta = s.wakeupsDelta
        cyclesDelta = s.cyclesDelta
        instructionsDelta = s.instructionsDelta
        messagesDelta = s.messagesDelta
        power = s.power
        gpu = s.gpu
        gpuTimeNs = s.gpuTimeNs
        network = s.network
        netInRate = s.netInRate
        netOutRate = s.netOutRate
        cpuHistory = s.cpuHistory
        memoryHistory = s.memoryHistory
        ioHistory = s.ioHistory
        gpuHistory = s.gpuHistory
        netHistory = s.netHistory
        firstSeen = s.firstSeen
        removedAt = s.removedAt
        isInitial = s.isInitial
        userName = s.userName
        bundleInfo = s.bundleInfo
    }

    public var pid: Int32 { record.pid }
    public var name: String { record.name }

    /// The application's name for an app's main executable (e.g. "Parallels Desktop" for
    /// prl_client_app), otherwise the executable name.
    public var displayName: String {
        if let b = bundleInfo, b.isApplication, b.isMainExecutable, let appName = b.displayName, !appName.isEmpty {
            return appName
        }
        return name
    }
    public var stats: TaskStats? { record.stats }
    public var isRemoved: Bool { removedAt != nil }

    /// Description column: bundle display name, otherwise empty.
    public var displayDescription: String {
        bundleInfo?.displayName ?? ""
    }

    public var signing: SigningInfo? {
        guard let path = record.path, !path.isEmpty else { return nil }
        return SigningCache.shared.info(for: path)
    }

    public var ioTotalRate: Double { diskReadRate + diskWriteRate }
    public var netTotalRate: Double { netInRate + netOutRate }

    /// Text used by the search filter.
    public func matches(_ m: SearchMatcher) -> Bool {
        if m.matchesIdentifier(String(record.pid)) { return true }
        if m.matchesAny(name, record.path, record.commandLine, record.title, userName) { return true }
        if let b = bundleInfo, m.matchesAny(b.displayName, b.bundleIdentifier) { return true }
        return false
    }

    /// All descendants (displayed children only).
    public var descendants: [ProcessItem] {
        children.flatMap { [$0] + $0.descendants }
    }
}

/// Mutable sampling state for one process. Owned exclusively by the store's background queue.
final class ProcessState {
    var record: ProcessRecord
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuKernel: Double = 0
    var diskReadRate: Double = 0
    var diskWriteRate: Double = 0
    var memoryDelta: Int64 = 0
    var faultsDelta: Int64 = 0
    var pageinsDelta: Int64 = 0
    var contextSwitchesDelta: Int64 = 0
    var syscallsDelta: Int64 = 0
    var wakeupsDelta: Int64 = 0
    var cyclesDelta: UInt64 = 0
    var instructionsDelta: UInt64 = 0
    var messagesDelta: Int64 = 0
    var power: Double = 0
    var gpu: Double = 0
    var gpuTimeNs: UInt64
    /// The GPU time last read for the process; see `GPUUsage.sample()`.
    private var lastGPUTime: UInt64
    var network: NetworkCounters?
    /// What nettop last reported for the process.
    private var lastNetwork: NetworkCounters?
    var netInRate: Double = 0
    var netOutRate: Double = 0
    var cpuHistory = History(capacity: 120)
    var memoryHistory = History(capacity: 120)
    var ioHistory = History(capacity: 120)
    var gpuHistory = History(capacity: 120)
    var netHistory = History(capacity: 120)
    let firstSeen = Date()
    var removedAt: Date?
    let isInitial: Bool
    var userName: String
    var bundleInfo: ExecutableBundleInfo?
    private var lastSampleTime: Double

    init(record: ProcessRecord, time: Double, initial: Bool, gpuTime: UInt64 = 0, network: NetworkCounters? = nil) {
        self.record = record
        isInitial = initial
        lastSampleTime = time
        gpuTimeNs = gpuTime
        lastGPUTime = gpuTime
        self.network = network
        lastNetwork = network
        userName = UserNames.name(record.uid)
        // Resolve file-system metadata here, off the main thread.
        bundleInfo = record.path.map { BundleInfoCache.shared.info(for: $0) }
    }

    func update(record new: ProcessRecord, time: Double, cpuCount: Int, scaleToSystem: Bool, gpuTime: UInt64 = 0,
                network: NetworkCounters?? = .none) {
        let dt = max(0.001, time - lastSampleTime)
        if case .some(let counters) = network {
            updateNetwork(counters, dt: dt)
        }
        // Closing a GPU connection takes its time out of the sum; count only growth.
        let gpuDelta = gpuTime &- min(gpuTime, lastGPUTime)
        gpuTimeNs &+= gpuDelta
        lastGPUTime = gpuTime
        gpu = Double(gpuDelta) / (dt * 1e9) * 100
        if let old = record.stats, let s = new.stats {
            let du = Double(s.userTimeNs &- min(s.userTimeNs, old.userTimeNs))
            let ds = Double(s.systemTimeNs &- min(s.systemTimeNs, old.systemTimeNs))
            let divisor = dt * 1e9 * (scaleToSystem ? Double(max(1, cpuCount)) : 1) / 100
            cpuUser = du / divisor
            cpuKernel = ds / divisor
            cpu = cpuUser + cpuKernel
            diskReadRate = Double(s.diskBytesRead &- min(s.diskBytesRead, old.diskBytesRead)) / dt
            diskWriteRate = Double(s.diskBytesWritten &- min(s.diskBytesWritten, old.diskBytesWritten)) / dt
            memoryDelta = Int64(bitPattern: s.physFootprint) - Int64(bitPattern: old.physFootprint)
            faultsDelta = Int64(s.faults) - Int64(old.faults)
            pageinsDelta = Int64(s.pageins) - Int64(old.pageins)
            contextSwitchesDelta = Int64(s.contextSwitches) - Int64(old.contextSwitches)
            syscallsDelta = s.syscalls - old.syscalls
            wakeupsDelta = Int64(bitPattern: s.wakeups &- old.wakeups)
            cyclesDelta = s.cycles &- min(s.cycles, old.cycles)
            instructionsDelta = s.instructions &- min(s.instructions, old.instructions)
            messagesDelta = (Int64(s.messagesSent) + Int64(s.messagesReceived)) - (Int64(old.messagesSent) + Int64(old.messagesReceived))
            power = Double(s.energyNj &- min(s.energyNj, old.energyNj)) / 1e9 / dt
        } else {
            cpu = 0
            cpuUser = 0
            cpuKernel = 0
            diskReadRate = 0
            diskWriteRate = 0
        }
        if new.uid != record.uid {
            userName = UserNames.name(new.uid)
        }
        if new.path != record.path {
            bundleInfo = new.path.map { BundleInfoCache.shared.info(for: $0) }
        }
        record = new
        lastSampleTime = time
        cpuHistory.append(cpu)
        memoryHistory.append(Double(new.stats?.physFootprint ?? 0))
        ioHistory.append(diskReadRate + diskWriteRate)
        gpuHistory.append(gpu)
        netHistory.append(netInRate + netOutRate)
    }

    /// Takes nettop's latest counters for the process (nil: no open sockets). Totals only grow:
    /// nettop's numbers cover the sockets open now, so they drop when one closes.
    private func updateNetwork(_ counters: NetworkCounters?, dt: Double) {
        guard counters != nil || network != nil else { return }
        let current = counters ?? NetworkCounters()
        let last = lastNetwork ?? NetworkCounters()
        func growth(_ now: UInt64, _ before: UInt64) -> UInt64 { now &- min(now, before) }
        let bytesIn = growth(current.bytesIn, last.bytesIn)
        let bytesOut = growth(current.bytesOut, last.bytesOut)
        var total = network ?? NetworkCounters()
        total.bytesIn &+= bytesIn
        total.bytesOut &+= bytesOut
        total.packetsIn &+= growth(current.packetsIn, last.packetsIn)
        total.packetsOut &+= growth(current.packetsOut, last.packetsOut)
        network = total
        lastNetwork = current
        netInRate = Double(bytesIn) / dt
        netOutRate = Double(bytesOut) / dt
    }

    func markRemoved() {
        removedAt = Date()
        gpu = 0
        netInRate = 0
        netOutRate = 0
        cpu = 0
        cpuUser = 0
        cpuKernel = 0
        diskReadRate = 0
        diskWriteRate = 0
    }
}

public struct ProcessFilterOptions: Equatable {
    public var text: String = ""
    public var hideOtherUsers = false
    public var hideSystemProcesses = false
    public var hideAppleProcesses = false
    public var hideZombies = false
    /// Treat the whole search text as a regular expression (`/pattern/` always is).
    public var regex = false
    /// Only GUI applications (see `ProcessStore.applicationPids`) and the processes they started.
    public var onlyApplications = false

    /// True when any option (other than the regex flag) narrows the list.
    public var isFiltering: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || hideOtherUsers || hideSystemProcesses
            || hideAppleProcesses || hideZombies || onlyApplications
    }

    public init() {}
}

/// Samples processes and system statistics periodically and maintains the process tree.
///
/// Threading: sampling, delta computation, filtering and tree building all run on a private serial
/// queue. The main thread only receives finished, immutable snapshots, so UI work never waits on
/// the kernel, the privileged helper, or the file system.
public final class ProcessStore: ObservableObject {
    public static let shared = ProcessStore()

    @Published public private(set) var revision = 0
    @Published public var paused = false
    /// Published snapshot (main thread).
    public private(set) var items: [ProcessKey: ProcessItem] = [:]
    public private(set) var roots: [ProcessItem] = []
    /// Visible items in display order (depth-first).
    public private(set) var visibleItems: [ProcessItem] = []
    public let system = SystemMonitor()
    public private(set) var lastError: String?
    /// Set when the search text is an invalid regular expression.
    @Published public private(set) var filterError: String?
    /// Number of processes that pass the current filters (excluding ancestors kept for the tree).
    public private(set) var matchCount = 0
    public private(set) var processCount = 0
    public private(set) var totalThreads = 0
    /// Supplies the PIDs of GUI applications for the "applications only" filter (set by the app).
    /// Called on the background queue.
    public var applicationPids: () -> Set<Int32> = { [] }

    public var interval: TimeInterval = 1.0 {
        didSet { if oldValue != interval { schedule() } }
    }
    public var highlightDuration: TimeInterval = 2.0
    public var scaleCPUToSystem = true
    public var treeMode = true {
        didSet { if oldValue != treeMode { rebuild() } }
    }
    public var filter = ProcessFilterOptions() {
        didSet { if oldValue != filter { rebuild() } }
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "process-store", qos: .userInitiated)
    private var sampling = false
    private var cancellables = Set<AnyCancellable>()
    /// Incremented for every requested publication; stale results are dropped.
    private var generation = 0

    // Background-queue state.
    private var states: [ProcessKey: ProcessState] = [:]
    private var hasSampled = false
    private var needsInterfaceBaseline = true

    public init() {
        NotificationCenter.default.publisher(for: Elevation.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshNow() }
            .store(in: &cancellables)
    }

    public func start() {
        if timer == nil {
            refreshNow()
            schedule()
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard interval > 0 else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, !self.paused else { return }
            self.refreshNow()
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private struct BuildOptions {
        var filter: ProcessFilterOptions
        var treeMode: Bool
        var highlightDuration: TimeInterval
        var scaleCPUToSystem: Bool
        var cpuCount: Int
    }

    private var currentOptions: BuildOptions {
        BuildOptions(filter: filter, treeMode: treeMode, highlightDuration: highlightDuration,
                     scaleCPUToSystem: scaleCPUToSystem, cpuCount: max(1, system.logicalCPUCount))
    }

    private struct Snapshot {
        var items: [ProcessKey: ProcessItem]
        var roots: [ProcessItem]
        var visible: [ProcessItem]
        var matchCount: Int
        var processCount: Int
        var totalThreads: Int
        var filterError: String?
    }

    /// Samples now (main thread entry point). Ignored while a sample is in flight.
    public func refreshNow() {
        guard !sampling else { return }
        sampling = true
        generation &+= 1
        let gen = generation
        let options = currentOptions
        queue.async { [weak self] in
            guard let self else { return }
            let response = Elevation.shared.perform(.sampleProcesses)
            let gpuTimes = GPUUsage.sample()
            let network = NetworkUsage.sample()
            // netstat's true interface totals, once (see InterfaceCounters).
            let interfaceBaseline = self.needsInterfaceBaseline ? InterfaceCounters.netstat() : nil
            self.needsInterfaceBaseline = false
            let sys = SystemSampler.sample()
            let time = Date().timeIntervalSince1970
            var error: String?
            if case .processes(let records) = response {
                self.merge(records, gpuTimes: gpuTimes, network: network, time: time, options: options)
            } else if case .failure(let e) = response {
                error = e.message
            }
            let snapshot = self.buildSnapshot(options)
            DispatchQueue.main.async {
                self.sampling = false
                self.lastError = error
                self.system.update(sys, processes: snapshot.items.values, interfaceBaseline: interfaceBaseline)
                self.publish(snapshot, generation: gen)
            }
        }
    }

    /// Re-filters and re-arranges the current data (e.g. after the search text changed).
    public func rebuild() {
        generation &+= 1
        let gen = generation
        let options = currentOptions
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.buildSnapshot(options)
            DispatchQueue.main.async {
                self.publish(snapshot, generation: gen)
            }
        }
    }

    private func publish(_ s: Snapshot, generation gen: Int) {
        // A newer request (e.g. another keystroke) supersedes this one; its result will follow.
        guard gen == generation else { return }
        items = s.items
        roots = s.roots
        visibleItems = s.visible
        matchCount = s.matchCount
        processCount = s.processCount
        totalThreads = s.totalThreads
        if filterError != s.filterError {
            filterError = s.filterError
        }
        revision &+= 1
    }

    public func item(pid: Int32) -> ProcessItem? {
        items.values.first { $0.pid == pid && !$0.isRemoved }
    }

    public func item(_ key: ProcessKey) -> ProcessItem? { items[key] }

    // MARK: Background queue

    /// `network` is nil when nettop couldn't be sampled; processes then keep their last counters.
    private func merge(_ records: [ProcessRecord], gpuTimes: [Int32: UInt64], network: [Int32: NetworkCounters]?,
                       time: Double, options: BuildOptions) {
        var seen = Set<ProcessKey>()
        seen.reserveCapacity(records.count)
        for r in records {
            seen.insert(r.key)
            if let state = states[r.key] {
                state.update(record: r, time: time, cpuCount: options.cpuCount, scaleToSystem: options.scaleCPUToSystem,
                             gpuTime: gpuTimes[r.pid] ?? 0, network: network.map { $0[r.pid] })
            } else {
                states[r.key] = ProcessState(record: r, time: time, initial: !hasSampled, gpuTime: gpuTimes[r.pid] ?? 0,
                                             network: network?[r.pid])
                if hasSampled {
                    EventLog.shared.add(.processStarted, pid: r.pid,
                                        "\(r.name) (\(r.pid)) started by \(UserNames.name(r.uid)), parent \(r.ppid)\(r.commandLine.map { ": \($0)" } ?? "")")
                }
            }
        }
        let now = Date()
        for (key, state) in states where !seen.contains(key) {
            if let removed = state.removedAt {
                if now.timeIntervalSince(removed) >= options.highlightDuration {
                    states.removeValue(forKey: key)
                }
            } else {
                state.markRemoved()
                let lifetime = Fmt.relative(seconds: Date().timeIntervalSince1970 - state.record.startTime)
                EventLog.shared.add(.processExited, pid: state.record.pid, "\(state.record.name) (\(state.record.pid)) exited after \(lifetime)")
            }
        }
        hasSampled = true
    }

    /// Creates fresh immutable items, links the tree, filters and orders it.
    private func buildSnapshot(_ options: BuildOptions) -> Snapshot {
        var items: [ProcessKey: ProcessItem] = [:]
        items.reserveCapacity(states.count)
        var processCount = 0
        var threads = 0
        for (key, state) in states {
            let item = ProcessItem(state)
            items[key] = item
            if item.removedAt == nil {
                processCount += 1
                threads += Int(item.record.stats?.threadCount ?? 0)
            }
        }
        let byPid = Dictionary(items.values.filter { !$0.isRemoved }.map { ($0.pid, $0) }, uniquingKeysWith: { a, b in
            a.record.startMicros > b.record.startMicros ? a : b
        })
        let f = options.filter
        let matcher = SearchMatcher(f.text, regex: f.regex)
        let me = Elevation.interactiveUid
        let appPids = f.onlyApplications ? applicationPids() : []

        func parentOf(_ item: ProcessItem) -> ProcessItem? {
            Self.treeParent(of: item, in: byPid)
        }

        // With "Apps", processes started by or for a GUI application (helpers, XPC services, a
        // terminal's shells and everything they run) count as part of it. Memoized so each chain
        // is walked once.
        var inApp: [ProcessKey: Bool] = [:]
        func belongsToApp(_ item: ProcessItem) -> Bool {
            var chain: [ProcessKey] = []
            var node: ProcessItem? = item
            var result = false
            while let n = node {
                if appPids.contains(n.record.pid) {
                    result = true
                    break
                }
                if let known = inApp[n.key] {
                    result = known
                    break
                }
                chain.append(n.key)
                node = chain.count < 512 ? parentOf(n) : nil
            }
            for key in chain {
                inApp[key] = result
            }
            return result
        }

        func passesOptions(_ item: ProcessItem) -> Bool {
            let r = item.record
            if f.hideOtherUsers, r.uid != me { return false }
            if f.hideSystemProcesses, r.uid < 500, r.uid != me { return false }
            if f.hideZombies, r.isZombie { return false }
            if f.onlyApplications, !belongsToApp(item) { return false }
            if f.hideAppleProcesses, let s = item.signing, s.isAppleSigned { return false }
            return true
        }

        var childMap: [ProcessKey: [ProcessItem]] = [:]
        var rootList: [ProcessItem] = []
        for item in items.values {
            if options.treeMode, let parent = parentOf(item) {
                item.parent = parent
                childMap[parent.key, default: []].append(item)
            } else {
                rootList.append(item)
            }
        }

        // Visibility: option filters + search (ancestors of matches stay visible in tree mode).
        var visible = Set<ProcessKey>()
        var matched = 0
        if matcher.isValid {
            for item in items.values where passesOptions(item) && (matcher.isEmpty || item.matches(matcher)) {
                if !item.isRemoved { matched += 1 }
                var node: ProcessItem? = item
                while let n = node, !visible.contains(n.key) {
                    visible.insert(n.key)
                    node = options.treeMode ? n.parent : nil
                }
            }
        }

        // Creation order; the table applies any user-selected column sort itself.
        let byCreation: (ProcessItem, ProcessItem) -> Bool = { a, b in
            a.record.startMicros != b.record.startMicros ? a.record.startMicros < b.record.startMicros : a.pid < b.pid
        }
        func arrange(_ list: [ProcessItem]) -> [ProcessItem] {
            list.filter { visible.contains($0.key) }.sorted(by: byCreation)
        }
        var ordered: [ProcessItem] = []
        ordered.reserveCapacity(visible.count)
        func walk(_ item: ProcessItem) {
            ordered.append(item)
            item.children = arrange(childMap[item.key] ?? [])
            item.children.forEach(walk)
        }
        let roots = arrange(rootList)
        roots.forEach(walk)
        return Snapshot(items: items, roots: roots, visible: ordered, matchCount: matched,
                        processCount: processCount, totalThreads: threads, filterError: matcher.error)
    }

    /// The live process `item` is listed under in the tree. Like Activity Monitor, that is the
    /// process that started it, except that processes launchd started on another's behalf (XPC
    /// services, helpers that daemonized) go under the process responsible for them. A reused PID
    /// that started later is neither.
    static func treeParent(of item: ProcessItem, in byPid: [Int32: ProcessItem]) -> ProcessItem? {
        let r = item.record
        var parent: ProcessItem?
        if r.pid != r.ppid, let p = byPid[r.ppid], p.record.startMicros <= r.startMicros || r.ppid == 0 {
            parent = p
        }
        // Strictly earlier, so these links can't form a cycle.
        if parent == nil || r.ppid == 1, let rp = r.responsiblePid, rp != r.pid, let p = byPid[rp],
           p.record.startMicros < r.startMicros {
            return p
        }
        return parent
    }

    /// Highlight state for row coloring.
    public func isNew(_ item: ProcessItem) -> Bool {
        !item.isInitial && item.removedAt == nil && Date().timeIntervalSince(item.firstSeen) < highlightDuration
    }
}

/// System-wide counters and histories.
public final class SystemMonitor {
    public private(set) var last: SystemSnapshot?
    public private(set) var cpuTotal = History()
    public private(set) var cpuUser = History()
    public private(set) var cpuKernel = History()
    public private(set) var perCore: [History] = []
    /// System (kernel) share of each core, parallel to `perCore`.
    public private(set) var perCoreKernel: [History] = []
    public private(set) var memoryUsed = History()
    public private(set) var memoryCompressed = History()
    public private(set) var memoryWired = History()
    public private(set) var swapUsed = History()
    /// Memory pressure as a percentage (100 minus the share the system considers available).
    public private(set) var memoryPressure = History()
    /// The pressure level at each sample (1 normal, 2 warning, 4 critical), parallel to `memoryPressure`.
    public private(set) var memoryPressureLevel = History()
    public private(set) var diskRead = History()
    public private(set) var diskWrite = History()
    public private(set) var diskReadOps = History()
    public private(set) var diskWriteOps = History()
    public private(set) var netIn = History()
    public private(set) var netOut = History()
    public private(set) var netInPackets = History()
    public private(set) var netOutPackets = History()
    public private(set) var gpu = History()
    public private(set) var power = History()
    /// Name of the top CPU consumer at each sample (parallel to cpuTotal).
    public private(set) var topCPUProcess: [String] = []
    public private(set) var topIOProcess: [String] = []
    public private(set) var topGPUProcess: [String] = []

    public private(set) var cpuUsage: Double = 0
    public private(set) var cpuUserUsage: Double = 0
    public private(set) var cpuKernelUsage: Double = 0
    public private(set) var coreUsage: [Double] = []
    public private(set) var diskReadRate: Double = 0
    public private(set) var diskWriteRate: Double = 0
    public private(set) var diskReadOpsRate: Double = 0
    public private(set) var diskWriteOpsRate: Double = 0
    public private(set) var netInRate: Double = 0
    public private(set) var netOutRate: Double = 0
    public private(set) var netInPacketsRate: Double = 0
    public private(set) var netOutPacketsRate: Double = 0
    /// Totals since boot over the non-loopback interfaces.
    public private(set) var netBytesIn: UInt64 = 0
    /// True totals per interface; see `InterfaceCounters`.
    public private(set) var interfaceTotals: [String: InterfaceCounters.Totals] = [:]
    public private(set) var netBytesOut: UInt64 = 0
    public private(set) var netPacketsIn: UInt64 = 0
    public private(set) var netPacketsOut: UInt64 = 0
    public private(set) var interfaceRates: [String: (rx: Double, tx: Double)] = [:]
    public private(set) var faultsRate: Double = 0
    public private(set) var pageinsRate: Double = 0
    public private(set) var pageoutsRate: Double = 0
    public private(set) var swapinsRate: Double = 0
    public private(set) var swapoutsRate: Double = 0
    public private(set) var compressionsRate: Double = 0
    public private(set) var decompressionsRate: Double = 0
    public private(set) var processPower: Double = 0

    public var logicalCPUCount: Int { last?.cpus.count ?? ProcessInfo.processInfo.activeProcessorCount }

    public init() {}

    /// `interfaceBaseline`: netstat's totals, passed with the first snapshot.
    func update(_ s: SystemSnapshot, processes: Dictionary<ProcessKey, ProcessItem>.Values,
                interfaceBaseline: [String: InterfaceCounters.Totals]? = nil) {
        defer { last = s }
        guard let prev = last else {
            perCore = Array(repeating: History(), count: s.cpus.count)
            perCoreKernel = perCore
            for i in s.interfaces {
                interfaceTotals[i.name] = interfaceBaseline?[i.name] ?? InterfaceCounters.Totals(i)
            }
            return
        }
        let dt = max(0.001, s.timestamp - prev.timestamp)
        // CPU
        var totalUser: UInt64 = 0, totalSys: UInt64 = 0, totalAll: UInt64 = 0
        var cores: [Double] = []
        var coresKernel: [Double] = []
        for (i, c) in s.cpus.enumerated() where i < prev.cpus.count {
            let p = prev.cpus[i]
            let u = (c.user &- p.user) &+ (c.nice &- p.nice)
            let sy = c.system &- p.system
            let all = c.total &- p.total
            totalUser &+= u
            totalSys &+= sy
            totalAll &+= all
            cores.append(all > 0 ? Double(u + sy) / Double(all) * 100 : 0)
            coresKernel.append(all > 0 ? Double(sy) / Double(all) * 100 : 0)
        }
        if perCore.count != cores.count {
            perCore = Array(repeating: History(), count: cores.count)
            perCoreKernel = perCore
        }
        for (i, v) in cores.enumerated() {
            perCore[i].append(v)
            perCoreKernel[i].append(coresKernel[i])
        }
        coreUsage = cores
        cpuUserUsage = totalAll > 0 ? Double(totalUser) / Double(totalAll) * 100 : 0
        cpuKernelUsage = totalAll > 0 ? Double(totalSys) / Double(totalAll) * 100 : 0
        cpuUsage = cpuUserUsage + cpuKernelUsage
        cpuTotal.append(cpuUsage)
        cpuUser.append(cpuUserUsage)
        cpuKernel.append(cpuKernelUsage)

        // Memory
        memoryUsed.append(Double(s.vm.usedBytes))
        memoryCompressed.append(Double(s.vm.compressedBytes))
        memoryWired.append(Double(s.vm.wiredBytes))
        swapUsed.append(Double(s.vm.swapUsed))
        memoryPressure.append(Double(100 - min(100, max(0, s.vm.availablePercent))))
        memoryPressureLevel.append(Double(s.vm.pressureLevel))
        func r(_ a: UInt64, _ b: UInt64) -> Double { Double(a &- min(a, b)) / dt }
        faultsRate = r(s.vm.faults, prev.vm.faults)
        pageinsRate = r(s.vm.pageins, prev.vm.pageins)
        pageoutsRate = r(s.vm.pageouts, prev.vm.pageouts)
        swapinsRate = r(s.vm.swapins, prev.vm.swapins)
        swapoutsRate = r(s.vm.swapouts, prev.vm.swapouts)
        compressionsRate = r(s.vm.compressions, prev.vm.compressions)
        decompressionsRate = r(s.vm.decompressions, prev.vm.decompressions)

        // Disk
        diskReadRate = r(s.disk.bytesRead, prev.disk.bytesRead)
        diskWriteRate = r(s.disk.bytesWritten, prev.disk.bytesWritten)
        diskReadOpsRate = r(s.disk.opsRead, prev.disk.opsRead)
        diskWriteOpsRate = r(s.disk.opsWritten, prev.disk.opsWritten)
        diskRead.append(diskReadRate)
        diskWrite.append(diskWriteRate)
        diskReadOps.append(diskReadOpsRate)
        diskWriteOps.append(diskWriteOpsRate)

        // Network (exclude loopback)
        var rx = 0.0, tx = 0.0, rxp = 0.0, txp = 0.0
        var rates: [String: (Double, Double)] = [:]
        let prevIfs = Dictionary(prev.interfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for i in s.interfaces {
            guard let p = prevIfs[i.name] else {
                interfaceTotals[i.name] = InterfaceCounters.Totals(i)
                continue
            }
            // The kernel's byte counts wrap at 32 bits for this process.
            let grown = InterfaceCounters.Totals(
                bytesIn: InterfaceCounters.growth(i.ibytes, p.ibytes), bytesOut: InterfaceCounters.growth(i.obytes, p.obytes),
                packetsIn: InterfaceCounters.growth(i.ipackets, p.ipackets), packetsOut: InterfaceCounters.growth(i.opackets, p.opackets))
            var total = interfaceTotals[i.name] ?? InterfaceCounters.Totals()
            total.bytesIn &+= grown.bytesIn
            total.bytesOut &+= grown.bytesOut
            total.packetsIn &+= grown.packetsIn
            total.packetsOut &+= grown.packetsOut
            interfaceTotals[i.name] = total
            let irx = Double(grown.bytesIn) / dt
            let itx = Double(grown.bytesOut) / dt
            rates[i.name] = (irx, itx)
            if !i.isLoopback {
                rx += irx
                tx += itx
                rxp += Double(grown.packetsIn) / dt
                txp += Double(grown.packetsOut) / dt
            }
        }
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0, packetsIn: UInt64 = 0, packetsOut: UInt64 = 0
        for i in s.interfaces where !i.isLoopback {
            guard let t = interfaceTotals[i.name] else { continue }
            bytesIn &+= t.bytesIn
            bytesOut &+= t.bytesOut
            packetsIn &+= t.packetsIn
            packetsOut &+= t.packetsOut
        }
        netBytesIn = bytesIn
        netBytesOut = bytesOut
        netPacketsIn = packetsIn
        netPacketsOut = packetsOut
        interfaceRates = rates
        netInRate = rx
        netOutRate = tx
        netInPacketsRate = rxp
        netOutPacketsRate = txp
        netInPackets.append(rxp)
        netOutPackets.append(txp)
        netIn.append(rx)
        netOut.append(tx)

        gpu.append(s.gpus.map(\.utilization).max() ?? 0)

        var topCPU: ProcessItem?
        var topIO: ProcessItem?
        var topGPU: ProcessItem?
        var watts = 0.0
        for p in processes where !p.isRemoved {
            if topCPU == nil || p.cpu > topCPU!.cpu { topCPU = p }
            if topIO == nil || p.ioTotalRate > topIO!.ioTotalRate { topIO = p }
            if p.gpu > (topGPU?.gpu ?? 0) { topGPU = p }
            watts += p.power
        }
        processPower = watts
        power.append(watts)
        func label(_ p: ProcessItem?, _ value: String) -> String {
            guard let p else { return "" }
            return "\(p.name) (\(p.pid)): \(value)"
        }
        topCPUProcess.append(label(topCPU, String(format: "%.1f%%", topCPU?.cpu ?? 0)))
        topIOProcess.append(label(topIO, Fmt.rate(topIO?.ioTotalRate ?? 0)))
        topGPUProcess.append(label(topGPU, String(format: "%.1f%%", topGPU?.gpu ?? 0)))
        if topCPUProcess.count > cpuTotal.capacity { topCPUProcess.removeFirst() }
        if topIOProcess.count > cpuTotal.capacity { topIOProcess.removeFirst() }
        if topGPUProcess.count > cpuTotal.capacity { topGPUProcess.removeFirst() }
    }
}
