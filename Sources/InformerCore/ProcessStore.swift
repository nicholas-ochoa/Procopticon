import Combine
import Darwin
import Foundation

/// Live state for one process. Accessed on the main thread only.
public final class ProcessItem: Identifiable {
    public let key: ProcessKey
    public var id: ProcessKey { key }
    public private(set) var record: ProcessRecord
    public weak var parent: ProcessItem?
    /// Children currently displayed (filtered, sorted).
    public var children: [ProcessItem] = []

    public private(set) var cpu: Double = 0
    public private(set) var cpuUser: Double = 0
    public private(set) var cpuKernel: Double = 0
    public private(set) var diskReadRate: Double = 0
    public private(set) var diskWriteRate: Double = 0
    public private(set) var memoryDelta: Int64 = 0
    public private(set) var faultsDelta: Int64 = 0
    public private(set) var pageinsDelta: Int64 = 0
    public private(set) var contextSwitchesDelta: Int64 = 0
    public private(set) var syscallsDelta: Int64 = 0
    public private(set) var wakeupsDelta: Int64 = 0
    public private(set) var cyclesDelta: UInt64 = 0
    public private(set) var instructionsDelta: UInt64 = 0
    public private(set) var messagesDelta: Int64 = 0
    public private(set) var power: Double = 0
    public private(set) var cpuHistory = History(capacity: 120)
    public private(set) var memoryHistory = History(capacity: 120)
    public private(set) var ioHistory = History(capacity: 120)
    public let firstSeen: Date
    public internal(set) var removedAt: Date?
    public internal(set) var isInitial: Bool

    private var lastSampleTime: Double

    init(record: ProcessRecord, time: Double, initial: Bool) {
        key = record.key
        self.record = record
        firstSeen = Date()
        isInitial = initial
        lastSampleTime = time
    }

    public var pid: Int32 { record.pid }
    public var name: String { record.name }
    public var stats: TaskStats? { record.stats }
    public var isRemoved: Bool { removedAt != nil }

    public var userName: String { UserNames.name(record.uid) }

    public var bundleInfo: ExecutableBundleInfo? {
        guard let path = record.path else { return nil }
        return BundleInfoCache.shared.info(for: path)
    }

    /// Description column: bundle display name, otherwise empty.
    public var displayDescription: String {
        bundleInfo?.displayName ?? ""
    }

    public var signing: SigningInfo? {
        guard let path = record.path, !path.isEmpty else { return nil }
        return SigningCache.shared.info(for: path)
    }

    public var ioTotalRate: Double { diskReadRate + diskWriteRate }

    func update(record new: ProcessRecord, time: Double, cpuCount: Int, scaleToSystem: Bool) {
        let dt = max(0.001, time - lastSampleTime)
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
        record = new
        lastSampleTime = time
        cpuHistory.append(cpu)
        memoryHistory.append(Double(new.stats?.physFootprint ?? 0))
        ioHistory.append(diskReadRate + diskWriteRate)
    }

    func markRemoved() {
        removedAt = Date()
        cpu = 0
        cpuUser = 0
        cpuKernel = 0
        diskReadRate = 0
        diskWriteRate = 0
    }

    /// Text used by the search filter.
    func matches(_ needle: String) -> Bool {
        if String(record.pid) == needle { return true }
        if name.localizedCaseInsensitiveContains(needle) { return true }
        if let p = record.path, p.localizedCaseInsensitiveContains(needle) { return true }
        if let c = record.commandLine, c.localizedCaseInsensitiveContains(needle) { return true }
        if userName.localizedCaseInsensitiveContains(needle) { return true }
        if let b = bundleInfo {
            if b.displayName?.localizedCaseInsensitiveContains(needle) == true { return true }
            if b.bundleIdentifier?.localizedCaseInsensitiveContains(needle) == true { return true }
        }
        return false
    }

    /// All descendants (displayed children only).
    public var descendants: [ProcessItem] {
        children.flatMap { [$0] + $0.descendants }
    }
}

public struct ProcessFilterOptions: Equatable {
    public var text: String = ""
    public var hideOtherUsers = false
    public var hideSystemProcesses = false
    public var hideAppleProcesses = false
    public var hideZombies = false

    public init() {}
}

/// Samples processes and system statistics periodically and maintains the process tree.
public final class ProcessStore: ObservableObject {
    public static let shared = ProcessStore()

    @Published public private(set) var revision = 0
    @Published public var paused = false
    public private(set) var items: [ProcessKey: ProcessItem] = [:]
    public private(set) var roots: [ProcessItem] = []
    /// Visible items in display order (depth-first).
    public private(set) var visibleItems: [ProcessItem] = []
    /// True when the last update added or removed displayed rows (vs. only changing values).
    public private(set) var structureChanged = true
    public let system = SystemMonitor()
    public private(set) var lastError: String?

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
    /// Sibling ordering. `nil` means creation order.
    public var sortComparator: ((ProcessItem, ProcessItem) -> Bool)? {
        didSet { rebuild() }
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "process-sampler", qos: .userInitiated)
    private var sampling = false
    private var hasSampled = false
    private var cancellables = Set<AnyCancellable>()

    public var totalThreads: Int {
        items.values.reduce(0) { $0 + Int($1.record.stats?.threadCount ?? 0) }
    }

    public var processCount: Int { items.values.filter { !$0.isRemoved }.count }

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

    public func refreshNow() {
        guard !sampling else { return }
        sampling = true
        queue.async { [weak self] in
            let response = Elevation.shared.perform(.sampleProcesses)
            let sys = SystemSampler.sample()
            let time = Date().timeIntervalSince1970
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false
                switch response {
                case .processes(let records):
                    self.lastError = nil
                    self.merge(records, time: time)
                case .failure(let e):
                    self.lastError = e.message
                default:
                    break
                }
                self.system.update(sys, processes: self.items.values)
                self.revision &+= 1
            }
        }
    }

    public func item(pid: Int32) -> ProcessItem? {
        items.values.first { $0.pid == pid && !$0.isRemoved }
    }

    public func item(_ key: ProcessKey) -> ProcessItem? { items[key] }

    private func merge(_ records: [ProcessRecord], time: Double) {
        let cpuCount = max(1, system.logicalCPUCount)
        var seen = Set<ProcessKey>()
        seen.reserveCapacity(records.count)
        for r in records {
            seen.insert(r.key)
            if let item = items[r.key] {
                item.update(record: r, time: time, cpuCount: cpuCount, scaleToSystem: scaleCPUToSystem)
            } else {
                let item = ProcessItem(record: r, time: time, initial: !hasSampled)
                items[r.key] = item
            }
        }
        let now = Date()
        for (key, item) in items where !seen.contains(key) {
            if item.removedAt == nil {
                item.markRemoved()
            } else if now.timeIntervalSince(item.removedAt!) >= highlightDuration {
                items.removeValue(forKey: key)
            }
        }
        hasSampled = true
        rebuild()
    }

    /// Rebuilds parent/child links and the visible ordering.
    public func rebuild() {
        let previous = visibleItems.map(\.key)
        let byPid = Dictionary(items.values.filter { !$0.isRemoved }.map { ($0.pid, $0) }, uniquingKeysWith: { a, b in
            a.record.startMicros > b.record.startMicros ? a : b
        })
        let f = filter
        let needle = f.text.trimmingCharacters(in: .whitespaces)
        let me = Elevation.interactiveUid

        func passesOptions(_ item: ProcessItem) -> Bool {
            let r = item.record
            if f.hideOtherUsers, r.uid != me { return false }
            if f.hideSystemProcesses, r.uid < 500, r.uid != me { return false }
            if f.hideZombies, r.isZombie { return false }
            if f.hideAppleProcesses, let s = item.signing, s.isAppleSigned { return false }
            return true
        }

        var childMap: [ProcessKey: [ProcessItem]] = [:]
        var rootList: [ProcessItem] = []
        for item in items.values {
            item.parent = nil
            let r = item.record
            if treeMode, r.pid != r.ppid, let parent = byPid[r.ppid], parent.key != item.key,
               parent.record.startMicros <= r.startMicros || r.ppid == 0 {
                item.parent = parent
                childMap[parent.key, default: []].append(item)
            } else {
                rootList.append(item)
            }
        }

        // Determine visibility: options filter + text filter (ancestors of matches stay visible).
        var visible = Set<ProcessKey>()
        for item in items.values where passesOptions(item) && (needle.isEmpty || item.matches(needle)) {
            var node: ProcessItem? = item
            while let n = node, !visible.contains(n.key) {
                visible.insert(n.key)
                node = treeMode ? n.parent : nil
            }
        }

        let comparator: (ProcessItem, ProcessItem) -> Bool = sortComparator ?? { a, b in
            a.record.startMicros != b.record.startMicros ? a.record.startMicros < b.record.startMicros : a.pid < b.pid
        }
        func arrange(_ list: [ProcessItem]) -> [ProcessItem] {
            list.filter { visible.contains($0.key) }.sorted(by: comparator)
        }
        var ordered: [ProcessItem] = []
        func walk(_ item: ProcessItem) {
            ordered.append(item)
            item.children = arrange(childMap[item.key] ?? [])
            item.children.forEach(walk)
        }
        roots = arrange(rootList)
        roots.forEach(walk)
        visibleItems = ordered
        structureChanged = previous != ordered.map(\.key)
        revision &+= 1
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
    public private(set) var memoryUsed = History()
    public private(set) var memoryCompressed = History()
    public private(set) var memoryWired = History()
    public private(set) var swapUsed = History()
    public private(set) var diskRead = History()
    public private(set) var diskWrite = History()
    public private(set) var netIn = History()
    public private(set) var netOut = History()
    public private(set) var gpu = History()
    public private(set) var power = History()
    /// Name of the top CPU consumer at each sample (parallel to cpuTotal).
    public private(set) var topCPUProcess: [String] = []
    public private(set) var topIOProcess: [String] = []

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

    func update(_ s: SystemSnapshot, processes: Dictionary<ProcessKey, ProcessItem>.Values) {
        defer { last = s }
        guard let prev = last else {
            perCore = Array(repeating: History(), count: s.cpus.count)
            return
        }
        let dt = max(0.001, s.timestamp - prev.timestamp)
        // CPU
        var totalUser: UInt64 = 0, totalSys: UInt64 = 0, totalAll: UInt64 = 0
        var cores: [Double] = []
        for (i, c) in s.cpus.enumerated() where i < prev.cpus.count {
            let p = prev.cpus[i]
            let u = (c.user &- p.user) &+ (c.nice &- p.nice)
            let sy = c.system &- p.system
            let all = c.total &- p.total
            totalUser &+= u
            totalSys &+= sy
            totalAll &+= all
            cores.append(all > 0 ? Double(u + sy) / Double(all) * 100 : 0)
        }
        if perCore.count != cores.count {
            perCore = Array(repeating: History(), count: cores.count)
        }
        for (i, v) in cores.enumerated() {
            perCore[i].append(v)
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

        // Network (exclude loopback)
        var rx = 0.0, tx = 0.0, rxp = 0.0, txp = 0.0
        var rates: [String: (Double, Double)] = [:]
        let prevIfs = Dictionary(prev.interfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for i in s.interfaces {
            guard let p = prevIfs[i.name] else { continue }
            let irx = r(i.ibytes, p.ibytes)
            let itx = r(i.obytes, p.obytes)
            rates[i.name] = (irx, itx)
            if !i.isLoopback {
                rx += irx
                tx += itx
                rxp += r(i.ipackets, p.ipackets)
                txp += r(i.opackets, p.opackets)
            }
        }
        interfaceRates = rates
        netInRate = rx
        netOutRate = tx
        netInPacketsRate = rxp
        netOutPacketsRate = txp
        netIn.append(rx)
        netOut.append(tx)

        gpu.append(s.gpus.map(\.utilization).max() ?? 0)

        var topCPU: ProcessItem?
        var topIO: ProcessItem?
        var watts = 0.0
        for p in processes where !p.isRemoved {
            if topCPU == nil || p.cpu > topCPU!.cpu { topCPU = p }
            if topIO == nil || p.ioTotalRate > topIO!.ioTotalRate { topIO = p }
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
        if topCPUProcess.count > cpuTotal.capacity { topCPUProcess.removeFirst() }
        if topIOProcess.count > cpuTotal.capacity { topIOProcess.removeFirst() }
    }
}
