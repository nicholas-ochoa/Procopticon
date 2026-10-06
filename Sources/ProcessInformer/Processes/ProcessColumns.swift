import AppKit
import InformerCore

typealias ProcessColumn = TableColumnSpec<ProcessItem>

enum ProcessColumns {
    static func all() -> [ProcessColumn] {
        var cols: [ProcessColumn] = []

        var name = ProcessColumn.string("name", "Name", width: 240) { $0.name }
        name.image = { ProcessIcons.icon(for: $0.record) }
        name.tooltip = { tooltip(for: $0) }
        name.monospacedDigits = false
        cols.append(name)

        cols.append(.number("pid", "PID", width: 60, value: { $0.pid }, text: { "\($0.pid)" }))
        cols.append(.number("cpu", "CPU", width: 55, help: "CPU usage (percent of total system capacity, or of one core — see Settings)",
                            value: { $0.cpu }, text: { Fmt.percent($0.cpu) }))
        cols.append(.number("memory", "Memory", width: 85, help: "Physical footprint: memory attributed to the process, including compressed pages",
                            value: { $0.stats?.physFootprint ?? 0 }, text: { s($0.stats?.physFootprint) }))
        cols.append(.number("ioTotalRate", "Disk rate", width: 80, help: "Disk read + write bytes per second",
                            value: { $0.ioTotalRate }, text: { Fmt.rate($0.ioTotalRate) }))
        cols.append(.string("user", "User name", width: 100) { $0.userName })
        cols.append(.string("description", "Description", width: 180) { $0.displayDescription })

        // Identity / image
        cols.append(.string("company", "Company", width: 150, visible: false, help: "Organization from the code signing certificate") {
            $0.signing?.organization ?? ""
        })
        cols.append(.string("version", "Version", width: 90, visible: false) { $0.bundleInfo?.versionString ?? "" })
        cols.append(.string("bundleId", "Bundle identifier", width: 180, visible: false) { $0.bundleInfo?.bundleIdentifier ?? "" })
        cols.append(.string("path", "File name", width: 260, visible: false) { $0.record.path ?? "" })
        cols.append(.string("commandLine", "Command line", width: 300, visible: false) { $0.record.commandLine ?? "" })
        cols.append(.string("arch", "Architecture", width: 90, visible: false) { $0.record.architecture })
        cols.append(.number("ppid", "Parent PID", width: 70, visible: false, value: { $0.record.ppid }, text: { "\($0.record.ppid)" }))
        cols.append(.number("responsible", "Responsible PID", width: 80, visible: false,
                            help: "The process macOS holds responsible for this one (e.g. the app that launched an XPC service)",
                            value: { $0.record.responsiblePid ?? 0 }, text: { $0.record.responsiblePid.map { "\($0)" } ?? "" }))
        cols.append(.number("pgid", "Process group", width: 70, visible: false, value: { $0.record.pgid }, text: { "\($0.record.pgid)" }))
        cols.append(.string("tty", "TTY", width: 70, visible: false) { $0.record.ttyName ?? "" })
        cols.append(.string("realUser", "Real user", width: 90, visible: false) { UserNames.name($0.record.ruid) })
        cols.append(.string("group", "Group", width: 80, visible: false) { UserNames.group($0.record.rgid) })
        cols.append(.string("state", "State", width: 80, visible: false) { $0.record.stateDescription })
        cols.append(.string("sandbox", "Sandboxed", width: 70, visible: false) { $0.record.sandboxed == true ? "Yes" : ($0.record.sandboxed == false ? "No" : "") })

        // Code signing
        cols.append(.string("verification", "Verification status", width: 140, visible: false) { $0.signing?.verificationSummary ?? "" })
        cols.append(.string("signer", "Verified signer", width: 200, visible: false) { $0.signing?.signer ?? "" })
        cols.append(.string("teamId", "Team ID", width: 90, visible: false) { $0.signing?.teamIdentifier ?? "" })
        cols.append(.string("hardened", "Hardened runtime", width: 70, visible: false) { p in
            guard let f = p.record.csFlags else { return "" }
            return f & CodeSigningFlags.runtime != 0 ? "Yes" : "No"
        })
        cols.append(.string("platform", "Platform binary", width: 70, visible: false) { p in
            guard let f = p.record.csFlags else { return "" }
            return f & CodeSigningFlags.platformBinary != 0 ? "Yes" : "No"
        })

        // CPU
        cols.append(.number("cpuUser", "CPU (user)", width: 60, visible: false, value: { $0.cpuUser }, text: { Fmt.percent($0.cpuUser) }))
        cols.append(.number("cpuKernel", "CPU (kernel)", width: 60, visible: false, value: { $0.cpuKernel }, text: { Fmt.percent($0.cpuKernel) }))
        cols.append(.number("cpuTime", "Total CPU time", width: 100, visible: false,
                            value: { $0.stats?.totalTimeNs ?? 0 }, text: { t($0.stats?.totalTimeNs) }))
        cols.append(.number("userTime", "User CPU time", width: 100, visible: false,
                            value: { $0.stats?.userTimeNs ?? 0 }, text: { t($0.stats?.userTimeNs) }))
        cols.append(.number("kernelTime", "Kernel CPU time", width: 100, visible: false,
                            value: { $0.stats?.systemTimeNs ?? 0 }, text: { t($0.stats?.systemTimeNs) }))
        cols.append(.number("pTime", "P-core time", width: 100, visible: false, help: "CPU time spent on performance cores",
                            value: { $0.stats?.pTimeNs ?? 0 }, text: { t($0.stats?.pTimeNs) }))
        cols.append(.number("priority", "Base priority", width: 60, visible: false,
                            value: { $0.stats?.priority ?? 0 }, text: { $0.stats.map { "\($0.priority)" } ?? "" }))
        cols.append(.number("nice", "Nice", width: 50, visible: false, value: { $0.record.nice }, text: { "\($0.record.nice)" }))
        cols.append(.number("threads", "Threads", width: 60, visible: false,
                            value: { $0.stats?.threadCount ?? 0 }, text: { $0.stats.map { "\($0.threadCount)" } ?? "" }))
        cols.append(.number("runningThreads", "Running threads", width: 60, visible: false,
                            value: { $0.stats?.runningThreads ?? 0 }, text: { $0.stats.map { "\($0.runningThreads)" } ?? "" }))
        cols.append(.number("fds", "Open files", width: 60, visible: false, help: "Number of open file descriptors",
                            value: { $0.record.fdCount ?? 0 }, text: { $0.record.fdCount.map { "\($0)" } ?? "" }))
        cols.append(.number("cycles", "Cycles", width: 110, visible: false,
                            value: { $0.stats?.cycles ?? 0 }, text: { $0.stats.map { Fmt.count($0.cycles) } ?? "" }))
        cols.append(.number("cyclesDelta", "Cycles delta", width: 110, visible: false,
                            value: { $0.cyclesDelta }, text: { $0.cyclesDelta == 0 ? "" : Fmt.count($0.cyclesDelta) }))
        cols.append(.number("instructions", "Instructions", width: 110, visible: false,
                            value: { $0.stats?.instructions ?? 0 }, text: { $0.stats.map { Fmt.count($0.instructions) } ?? "" }))
        cols.append(.number("instructionsDelta", "Instructions delta", width: 110, visible: false,
                            value: { $0.instructionsDelta }, text: { $0.instructionsDelta == 0 ? "" : Fmt.count($0.instructionsDelta) }))
        cols.append(.number("ipc", "IPC", width: 50, visible: false, help: "Instructions per cycle over the last interval",
                            value: { ipc($0) }, text: { ipc($0) > 0 ? String(format: "%.2f", ipc($0)) : "" }))
        cols.append(.number("csw", "Context switches", width: 100, visible: false,
                            value: { $0.stats?.contextSwitches ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.contextSwitches)) } ?? "" }))
        cols.append(.number("cswDelta", "Context switches delta", width: 90, visible: false,
                            value: { $0.contextSwitchesDelta }, text: { Fmt.delta($0.contextSwitchesDelta) }))
        cols.append(.number("syscalls", "System calls", width: 100, visible: false,
                            value: { $0.stats?.syscalls ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.syscalls)) } ?? "" }))
        cols.append(.number("syscallsDelta", "System calls delta", width: 90, visible: false,
                            value: { $0.syscallsDelta }, text: { Fmt.delta($0.syscallsDelta) }))
        cols.append(.number("wakeups", "Idle wake-ups", width: 90, visible: false,
                            value: { $0.stats?.wakeups ?? 0 }, text: { $0.stats.map { Fmt.count($0.wakeups) } ?? "" }))
        cols.append(.number("wakeupsDelta", "Wake-ups delta", width: 80, visible: false,
                            value: { $0.wakeupsDelta }, text: { Fmt.delta($0.wakeupsDelta) }))
        cols.append(.number("power", "Power", width: 70, visible: false, help: "Estimated power draw from the kernel energy counters",
                            value: { $0.power }, text: { Fmt.watts($0.power) }))
        cols.append(.number("energy", "Energy", width: 90, visible: false, help: "Total energy consumed since launch",
                            value: { $0.stats?.energyNj ?? 0 }, text: { e($0.stats?.energyNj) }))
        cols.append(.number("messages", "Mach messages", width: 100, visible: false,
                            value: { Int64($0.stats?.messagesSent ?? 0) + Int64($0.stats?.messagesReceived ?? 0) },
                            text: { p in p.stats.map { Fmt.count(Int($0.messagesSent) + Int($0.messagesReceived)) } ?? "" }))
        cols.append(.number("messagesDelta", "Mach messages delta", width: 90, visible: false,
                            value: { $0.messagesDelta }, text: { Fmt.delta($0.messagesDelta) }))

        // Memory
        cols.append(.number("peakMemory", "Peak memory", width: 85, visible: false,
                            value: { $0.stats?.lifetimeMaxFootprint ?? 0 }, text: { s($0.stats?.lifetimeMaxFootprint) }))
        cols.append(.number("memoryDelta", "Memory delta", width: 85, visible: false,
                            value: { $0.memoryDelta }, text: { $0.memoryDelta == 0 ? "" : Fmt.bytes($0.memoryDelta) }))
        cols.append(.number("resident", "Resident size", width: 85, visible: false, help: "Physical pages currently resident (includes shared)",
                            value: { $0.stats?.residentSize ?? 0 }, text: { s($0.stats?.residentSize) }))
        cols.append(.number("virtual", "Virtual size", width: 90, visible: false,
                            value: { $0.stats?.virtualSize ?? 0 }, text: { s($0.stats?.virtualSize) }))
        cols.append(.number("wired", "Wired memory", width: 85, visible: false,
                            value: { $0.stats?.wiredSize ?? 0 }, text: { s($0.stats?.wiredSize) }))
        cols.append(.number("neural", "Neural Engine memory", width: 85, visible: false,
                            value: { $0.stats?.neuralFootprint ?? 0 }, text: { s($0.stats?.neuralFootprint) }))
        cols.append(.number("faults", "Page faults", width: 90, visible: false,
                            value: { $0.stats?.faults ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.faults)) } ?? "" }))
        cols.append(.number("faultsDelta", "Page faults delta", width: 80, visible: false,
                            value: { $0.faultsDelta }, text: { Fmt.delta($0.faultsDelta) }))
        cols.append(.number("pageins", "Page-ins", width: 80, visible: false,
                            value: { $0.stats?.pageins ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.pageins)) } ?? "" }))
        cols.append(.number("cowFaults", "Copy-on-write faults", width: 90, visible: false,
                            value: { $0.stats?.cowFaults ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.cowFaults)) } ?? "" }))

        // Disk
        cols.append(.number("diskRead", "Disk read bytes", width: 90, visible: false,
                            value: { $0.stats?.diskBytesRead ?? 0 }, text: { s($0.stats?.diskBytesRead) }))
        cols.append(.number("diskWrite", "Disk write bytes", width: 90, visible: false,
                            value: { $0.stats?.diskBytesWritten ?? 0 }, text: { s($0.stats?.diskBytesWritten) }))
        cols.append(.number("diskReadRate", "Disk read rate", width: 85, visible: false,
                            value: { $0.diskReadRate }, text: { Fmt.rate($0.diskReadRate) }))
        cols.append(.number("diskWriteRate", "Disk write rate", width: 85, visible: false,
                            value: { $0.diskWriteRate }, text: { Fmt.rate($0.diskWriteRate) }))
        cols.append(.number("logicalWrites", "Logical writes", width: 90, visible: false,
                            value: { $0.stats?.logicalWrites ?? 0 }, text: { s($0.stats?.logicalWrites) }))

        // Time
        cols.append(.number("startTime", "Start time", width: 140, visible: false,
                            value: { $0.record.startMicros }, text: { Fmt.date($0.record.startTime) }))
        cols.append(.number("runningTime", "Running time", width: 100, visible: false,
                            value: { -$0.record.startMicros }, text: { Fmt.relative(seconds: Date().timeIntervalSince1970 - $0.record.startTime) }))

        // Graphs
        var cpuGraph = ProcessColumn("cpuHistory", "CPU history", width: 80, visible: false, text: { _ in "" }, less: { $0.cpu < $1.cpu })
        cpuGraph.kind = .graph
        cpuGraph.graph = { GraphCellData(values: $0.cpuHistory.ordered, maxValue: 100, color: .systemGreen) }
        cols.append(cpuGraph)
        var memGraph = ProcessColumn("memoryHistory", "Memory history", width: 80, visible: false, text: { _ in "" },
                                     less: { ($0.stats?.physFootprint ?? 0) < ($1.stats?.physFootprint ?? 0) })
        memGraph.kind = .graph
        memGraph.graph = { GraphCellData(values: $0.memoryHistory.ordered, maxValue: max(1, $0.memoryHistory.maxValue), color: .systemOrange) }
        cols.append(memGraph)
        var ioGraph = ProcessColumn("ioHistory", "Disk history", width: 80, visible: false, text: { _ in "" },
                                    less: { $0.ioTotalRate < $1.ioTotalRate })
        ioGraph.kind = .graph
        ioGraph.graph = { GraphCellData(values: $0.ioHistory.ordered, maxValue: max(1, $0.ioHistory.maxValue), color: .systemBlue) }
        cols.append(ioGraph)

        return cols
    }

    private static func s(_ v: UInt64?) -> String {
        guard let v, v > 0 else { return "" }
        return Fmt.bytes(v)
    }

    private static func t(_ ns: UInt64?) -> String {
        guard let ns else { return "" }
        return Fmt.duration(nanoseconds: ns)
    }

    private static func e(_ nj: UInt64?) -> String {
        guard let nj, nj > 0 else { return "" }
        let joules = Double(nj) / 1e9
        if joules >= 3600 {
            return String(format: "%.2f Wh", joules / 3600)
        }
        return String(format: "%.1f J", joules)
    }

    private static func ipc(_ p: ProcessItem) -> Double {
        p.cyclesDelta > 0 ? Double(p.instructionsDelta) / Double(p.cyclesDelta) : 0
    }

    static func tooltip(for p: ProcessItem) -> String {
        var lines: [String] = []
        if let path = p.record.path { lines.append(path) }
        if let cmd = p.record.commandLine, cmd != p.record.path { lines.append("Command line: \(cmd)") }
        if let b = p.bundleInfo {
            if let name = b.displayName { lines.append("\(name) \(b.versionString)") }
            if let id = b.bundleIdentifier { lines.append("Bundle: \(id)") }
        }
        if let s = p.signing, !s.signer.isEmpty {
            lines.append("Signer: \(s.signer)")
        }
        var notes: [String] = []
        if p.record.sandboxed == true { notes.append("Sandboxed") }
        if p.record.isTranslated { notes.append("Running under Rosetta") }
        if p.record.isTraced { notes.append("Being traced") }
        if p.record.isStopped { notes.append("Stopped") }
        if p.record.isElevated { notes.append("Elevated (euid root)") }
        if let r = p.record.responsiblePid, r != p.pid, let rp = ProcessStore.shared.item(pid: r) {
            notes.append("Responsible: \(rp.name) (\(r))")
        }
        if !notes.isEmpty { lines.append(notes.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}
