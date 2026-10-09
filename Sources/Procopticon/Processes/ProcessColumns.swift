import AppKit
import ProcopticonCore
import SwiftUI

typealias ProcessColumn = TableColumnSpec<ProcessItem>

enum ProcessColumns {
    /// Built once; column closures are pure functions of the item.
    static let shared: [ProcessColumn] = all()

    static func all() -> [ProcessColumn] {
        var cols: [ProcessColumn] = []

        var name = ProcessColumn.string("name", "Name", width: 240,
                                        help: "The executable's name, or the app's name for an app's main executable") { $0.displayName }
        name.image = { ProcessIcons.icon(for: $0.record) }
        // Like Activity Monitor, a hung application says so after its name.
        name.attributedText = { p in
            let text = NSMutableAttributedString(string: p.displayName)
            if p.isNotResponding {
                text.append(NSAttributedString(string: " (Not Responding)", attributes: [.foregroundColor: NSColor.systemRed]))
            }
            return text
        }
        name.richTooltip = { AnyView(ProcessToolTipView(item: $0)) }
        name.monospacedDigits = false
        cols.append(name)

        cols.append(.number("pid", "PID", width: 60, help: "Process ID", value: { $0.pid }, text: { "\($0.pid)" }))
        var cpu = ProcessColumn.number("cpu", "CPU", width: 55, help: "CPU usage (percent of total system capacity, or of one core — see Settings)",
                                       value: { shown($0.cpu) }, text: { Fmt.percent($0.cpu) })
        cpu.attributedText = { cpuPercent($0.cpu) }
        cols.append(cpu)
        cols.append(.number("memory", "Memory", width: 85, help: "Physical footprint: memory attributed to the process, including compressed pages",
                            value: { $0.stats?.physFootprint ?? 0 }, text: { s($0.stats?.physFootprint) }))
        cols.append(.number("ioTotalRate", "Disk rate", width: 80, help: "Disk read + write bytes per second",
                            value: { $0.ioTotalRate }, text: { Fmt.rate($0.ioTotalRate) }))
        cols.append(.number("gpu", "GPU", width: 55, help: "GPU usage: the share of the GPU's time spent on the process's work",
                            value: { shown($0.gpu) }, text: { Fmt.percent($0.gpu) }))
        cols.append(.number("gpuTime", "GPU time", width: 90, visible: false,
                            help: "GPU time used by the process's open connections to the GPU",
                            value: { $0.gpuTimeNs }, text: { $0.gpuTimeNs > 0 ? Fmt.duration(nanoseconds: $0.gpuTimeNs) : "" }))

        // Network (from nettop: the process's sockets when first seen, plus their traffic since)
        cols.append(.number("netInRate", "Receive rate", width: 85, visible: false, help: "Bytes received per second",
                            value: { $0.netInRate }, text: { Fmt.rate($0.netInRate) }))
        cols.append(.number("netOutRate", "Send rate", width: 85, visible: false, help: "Bytes sent per second",
                            value: { $0.netOutRate }, text: { Fmt.rate($0.netOutRate) }))
        var netRate = ProcessColumn.number("netRate", "Network rate", width: 160, visible: false,
                                           help: "Receive (↓) and send (↑) rates; sorts by their total",
                                           value: { $0.netTotalRate }, text: { networkRate($0).string })
        netRate.attributedText = { networkRate($0) }
        cols.append(netRate)
        cols.append(.number("netIn", "Received bytes", width: 90, visible: false,
                            help: "Data received by the process's sockets: what they had received when Procopticon first saw them, plus everything since",
                            value: { $0.network?.bytesIn ?? 0 }, text: { s($0.network?.bytesIn) }))
        cols.append(.number("netOut", "Sent bytes", width: 90, visible: false,
                            help: "Data sent by the process's sockets: what they had sent when Procopticon first saw them, plus everything since",
                            value: { $0.network?.bytesOut ?? 0 }, text: { s($0.network?.bytesOut) }))
        cols.append(.number("netInPackets", "Received packets", width: 90, visible: false, help: "Packets received by the process's sockets",
                            value: { $0.network?.packetsIn ?? 0 }, text: { c($0.network?.packetsIn) }))
        cols.append(.number("netOutPackets", "Sent packets", width: 90, visible: false, help: "Packets sent by the process's sockets",
                            value: { $0.network?.packetsOut ?? 0 }, text: { c($0.network?.packetsOut) }))
        cols.append(.string("user", "User name", width: 100, help: "The user the process runs as (its effective user)") { $0.userName })
        // Falls back to the process title, so retitled processes (often without a bundle) aren't blank.
        cols.append(.string("description", "Description", width: 180,
                            help: "The app's or bundle's display name, or the process title when there isn't one") { p in
            let description = p.displayDescription
            return description.isEmpty ? p.record.title ?? "" : description
        })
        cols.append(.string("title", "Process title", width: 220,
                            help: "The title a process set for itself in place of its command line (as htop shows after “│”)") {
            $0.record.title ?? ""
        })

        // Identity / image
        cols.append(.string("company", "Company", width: 150, visible: false, help: "Organization from the code signing certificate") {
            $0.signing?.organization ?? ""
        })
        cols.append(.string("version", "Version", width: 90, visible: false,
                            help: "Version from the enclosing app or bundle's Info.plist") { $0.bundleInfo?.versionString ?? "" })
        cols.append(.string("bundleId", "Bundle identifier", width: 180, visible: false,
                            help: "Bundle identifier of the enclosing app or bundle") { $0.bundleInfo?.bundleIdentifier ?? "" })
        cols.append(.string("path", "File name", width: 260, visible: false, help: "Full path of the executable") { $0.record.path ?? "" })
        var commandLine = ProcessColumn.string("commandLine", "Command line", width: 300, visible: false,
                                               help: "The executable and the arguments the process was started with") { $0.record.commandLine ?? "" }
        commandLine.attributedText = { CommandLineStyle.commandLine($0.record.commandLineArguments ?? []) }
        commandLine.richTooltip = { AnyView(ProcessToolTipView(item: $0)) }
        cols.append(commandLine)
        cols.append(.string("arch", "Architecture", width: 90, visible: false,
                            help: "The architecture the process runs as (arm64, or x86_64 under Rosetta)") { $0.record.architecture })
        cols.append(.number("ppid", "Parent PID", width: 70, visible: false,
                            help: "Process ID of the parent process",
                            value: { $0.record.ppid }, text: { "\($0.record.ppid)" }))
        cols.append(.number("responsible", "Responsible PID", width: 80, visible: false,
                            help: "The process macOS holds responsible for this one (e.g. the app that launched an XPC service)",
                            value: { $0.record.responsiblePid ?? 0 }, text: { $0.record.responsiblePid.map { "\($0)" } ?? "" }))
        cols.append(.number("pgid", "Process group", width: 70, visible: false,
                            help: "Process group ID; the processes of a shell job share one",
                            value: { $0.record.pgid }, text: { "\($0.record.pgid)" }))
        cols.append(.string("tty", "TTY", width: 70, visible: false, help: "The process's controlling terminal") { $0.record.ttyName ?? "" })
        cols.append(.string("realUser", "Real user", width: 90, visible: false,
                            help: "The user who started the process; differs from User name for setuid programs") { UserNames.name($0.record.ruid) })
        cols.append(.string("group", "Group", width: 80, visible: false, help: "The process's real group") { UserNames.group($0.record.rgid) })
        cols.append(.string("state", "State", width: 80, visible: false,
                            help: "Scheduling state: running, sleeping, idle, stopped or zombie") { $0.record.stateDescription })
        var responding = ProcessColumn.string("responding", "Responding", width: 130, visible: false,
                                              help: "Whether an application is responding to events, as the spinning wait cursor shows, and for how long it hasn't been; blank for processes without a user interface") {
            respondingText($0)
        }
        responding.attributedText = { p in
            NSAttributedString(string: respondingText(p), attributes: p.isNotResponding ? [.foregroundColor: NSColor.systemRed] : [:])
        }
        cols.append(responding)
        cols.append(.string("sandbox", "Sandboxed", width: 70, visible: false,
                            help: "Whether the process runs in the App Sandbox") { p in
            p.record.sandboxed == true ? "Yes" : (p.record.sandboxed == false ? "No" : "")
        })

        // Code signing
        cols.append(.string("verification", "Verification status", width: 140, visible: false,
                            help: "Result of checking the executable's code signature") { $0.signing?.verificationSummary ?? "" })
        cols.append(.string("signer", "Verified signer", width: 200, visible: false,
                            help: "Who signed the executable, from its code signing certificate") { $0.signing?.signer ?? "" })
        cols.append(.string("teamId", "Team ID", width: 90, visible: false,
                            help: "Apple Developer Team ID from the executable's code signature") { $0.signing?.teamIdentifier ?? "" })
        cols.append(.string("hardened", "Hardened runtime", width: 70, visible: false,
                            help: "Whether the executable was signed with the hardened runtime") { p in
            guard let f = p.record.csFlags else { return "" }
            return f & CodeSigningFlags.runtime != 0 ? "Yes" : "No"
        })
        cols.append(.string("platform", "Platform binary", width: 70, visible: false,
                            help: "Whether the executable is an Apple platform binary (part of macOS)") { p in
            guard let f = p.record.csFlags else { return "" }
            return f & CodeSigningFlags.platformBinary != 0 ? "Yes" : "No"
        })

        // CPU
        var cpuUser = ProcessColumn.number("cpuUser", "CPU (user)", width: 60, visible: false,
                                           help: "CPU usage running the process's own code (user mode)",
                                           value: { $0.cpuUser }, text: { Fmt.percent($0.cpuUser) })
        cpuUser.attributedText = { cpuPercent($0.cpuUser) }
        cols.append(cpuUser)
        var cpuKernel = ProcessColumn.number("cpuKernel", "CPU (kernel)", width: 60, visible: false,
                                             help: "CPU usage in the kernel on the process's behalf (system calls, I/O)",
                                             value: { $0.cpuKernel }, text: { Fmt.percent($0.cpuKernel) })
        cpuKernel.attributedText = { cpuPercent($0.cpuKernel) }
        cols.append(cpuKernel)
        cols.append(.number("cpuTime", "Total CPU time", width: 100, visible: false,
                            help: "CPU time used since the process started, in user mode and in the kernel",
                            value: { $0.stats?.totalTimeNs ?? 0 }, text: { t($0.stats?.totalTimeNs) }))
        cols.append(.number("userTime", "User CPU time", width: 100, visible: false,
                            help: "CPU time spent running the process's own code (user mode)",
                            value: { $0.stats?.userTimeNs ?? 0 }, text: { t($0.stats?.userTimeNs) }))
        cols.append(.number("kernelTime", "Kernel CPU time", width: 100, visible: false, help: "CPU time spent in the kernel on the process's behalf",
                            value: { $0.stats?.systemTimeNs ?? 0 }, text: { t($0.stats?.systemTimeNs) }))
        cols.append(.number("pTime", "P-core time", width: 100, visible: false, help: "CPU time spent on performance cores",
                            value: { $0.stats?.pTimeNs ?? 0 }, text: { t($0.stats?.pTimeNs) }))
        cols.append(.number("priority", "Base priority", width: 60, visible: false, help: "Base scheduling priority; higher runs first",
                            value: { $0.stats?.priority ?? 0 }, text: { $0.stats.map { "\($0.priority)" } ?? "" }))
        cols.append(.number("nice", "Nice", width: 50, visible: false,
                            help: "Nice value, from −20 (most favored) to 20 (least favored)",
                            value: { $0.record.nice }, text: { "\($0.record.nice)" }))
        cols.append(.number("threads", "Threads", width: 60, visible: false, help: "Number of threads",
                            value: { $0.stats?.threadCount ?? 0 }, text: { $0.stats.map { "\($0.threadCount)" } ?? "" }))
        cols.append(.number("runningThreads", "Running threads", width: 60, visible: false, help: "Threads running or ready to run",
                            value: { $0.stats?.runningThreads ?? 0 }, text: { $0.stats.map { "\($0.runningThreads)" } ?? "" }))
        cols.append(.number("fds", "Open files", width: 60, visible: false, help: "Number of open file descriptors",
                            value: { $0.record.fdCount ?? 0 }, text: { $0.record.fdCount.map { "\($0)" } ?? "" }))
        cols.append(.number("cycles", "Cycles", width: 110, visible: false, help: "CPU cycles used since the process started",
                            value: { $0.stats?.cycles ?? 0 }, text: { $0.stats.map { Fmt.count($0.cycles) } ?? "" }))
        cols.append(.number("cyclesDelta", "Cycles delta", width: 110, visible: false, help: "CPU cycles used over the last update interval",
                            value: { $0.cyclesDelta }, text: { $0.cyclesDelta == 0 ? "" : Fmt.count($0.cyclesDelta) }))
        cols.append(.number("instructions", "Instructions", width: 110, visible: false, help: "Instructions executed since the process started",
                            value: { $0.stats?.instructions ?? 0 }, text: { $0.stats.map { Fmt.count($0.instructions) } ?? "" }))
        cols.append(.number("instructionsDelta", "Instructions delta", width: 110, visible: false,
                            help: "Instructions executed over the last update interval",
                            value: { $0.instructionsDelta }, text: { $0.instructionsDelta == 0 ? "" : Fmt.count($0.instructionsDelta) }))
        cols.append(.number("ipc", "IPC", width: 50, visible: false, help: "Instructions per cycle over the last interval",
                            value: { ipc($0) }, text: { ipc($0) > 0 ? String(format: "%.2f", ipc($0)) : "" }))
        cols.append(.number("csw", "Context switches", width: 100, visible: false, help: "Context switches since the process started",
                            value: { $0.stats?.contextSwitches ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.contextSwitches)) } ?? "" }))
        cols.append(.number("cswDelta", "Context switches delta", width: 90, visible: false, help: "Context switches over the last update interval",
                            value: { $0.contextSwitchesDelta }, text: { Fmt.delta($0.contextSwitchesDelta) }))
        cols.append(.number("syscalls", "System calls", width: 100, visible: false, help: "System calls (Unix and Mach) since the process started",
                            value: { $0.stats?.syscalls ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.syscalls)) } ?? "" }))
        cols.append(.number("syscallsDelta", "System calls delta", width: 90, visible: false, help: "System calls over the last update interval",
                            value: { $0.syscallsDelta }, text: { Fmt.delta($0.syscallsDelta) }))
        cols.append(.number("wakeups", "Idle wake-ups", width: 90, visible: false,
                            help: "Times the process woke a CPU (idle and interrupt wake-ups) since it started",
                            value: { $0.stats?.wakeups ?? 0 }, text: { $0.stats.map { Fmt.count($0.wakeups) } ?? "" }))
        cols.append(.number("wakeupsDelta", "Wake-ups delta", width: 80, visible: false, help: "Wake-ups over the last update interval",
                            value: { $0.wakeupsDelta }, text: { Fmt.delta($0.wakeupsDelta) }))
        cols.append(.number("power", "Power", width: 70, visible: false, help: "Estimated power draw from the kernel energy counters",
                            value: { $0.power }, text: { Fmt.watts($0.power) }))
        cols.append(.number("energy", "Energy", width: 90, visible: false, help: "Total energy consumed since launch",
                            value: { $0.stats?.energyNj ?? 0 }, text: { e($0.stats?.energyNj) }))
        cols.append(ProcessColumn("preventingSleep", "Preventing Sleep", width: 90, visible: false,
                                  help: "Whether the process keeps the Mac awake with a power assertion: System (the Mac stays awake; the display may sleep) or Display (the display stays on too)",
                                  text: { $0.sleepPrevention?.title ?? "" },
                                  less: { ($0.sleepPrevention?.rawValue ?? 0) < ($1.sleepPrevention?.rawValue ?? 0) }))
        cols.append(ProcessColumn("assertions", "Power assertions", width: 200, visible: false,
                                  help: "The power assertions the process holds, or another holds for it (pmset -g assertions); see Properties ▸ Power",
                                  text: { assertionTypes($0) },
                                  less: { $0.assertions.count < $1.assertions.count }))
        cols.append(.number("messages", "Mach messages", width: 100, visible: false,
                            help: "Mach messages sent and received since the process started",
                            value: { Int64($0.stats?.messagesSent ?? 0) + Int64($0.stats?.messagesReceived ?? 0) },
                            text: { p in p.stats.map { Fmt.count(Int($0.messagesSent) + Int($0.messagesReceived)) } ?? "" }))
        cols.append(.number("messagesDelta", "Mach messages delta", width: 90, visible: false,
                            help: "Mach messages sent and received over the last update interval",
                            value: { $0.messagesDelta }, text: { Fmt.delta($0.messagesDelta) }))

        // Memory
        cols.append(.number("peakMemory", "Peak memory", width: 85, visible: false, help: "Highest memory footprint since the process started",
                            value: { $0.stats?.lifetimeMaxFootprint ?? 0 }, text: { s($0.stats?.lifetimeMaxFootprint) }))
        cols.append(.number("memoryDelta", "Memory delta", width: 85, visible: false,
                            help: "Change in memory footprint over the last update interval",
                            value: { $0.memoryDelta }, text: { $0.memoryDelta == 0 ? "" : Fmt.bytes($0.memoryDelta) }))
        cols.append(.number("resident", "Resident size", width: 85, visible: false, help: "Physical pages currently resident (includes shared)",
                            value: { $0.stats?.residentSize ?? 0 }, text: { s($0.stats?.residentSize) }))
        cols.append(.number("virtual", "Virtual size", width: 90, visible: false,
                            help: "Virtual address space the process has reserved; most of it uses no memory",
                            value: { $0.stats?.virtualSize ?? 0 }, text: { s($0.stats?.virtualSize) }))
        cols.append(.number("wired", "Wired memory", width: 85, visible: false,
                            help: "Memory locked in RAM for the process, which can't be paged out or compressed",
                            value: { $0.stats?.wiredSize ?? 0 }, text: { s($0.stats?.wiredSize) }))
        cols.append(.number("neural", "Neural Engine memory", width: 85, visible: false, help: "Memory used by the Neural Engine for the process",
                            value: { $0.stats?.neuralFootprint ?? 0 }, text: { s($0.stats?.neuralFootprint) }))
        cols.append(.number("faults", "Page faults", width: 90, visible: false, help: "Page faults since the process started",
                            value: { $0.stats?.faults ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.faults)) } ?? "" }))
        cols.append(.number("faultsDelta", "Page faults delta", width: 80, visible: false, help: "Page faults over the last update interval",
                            value: { $0.faultsDelta }, text: { Fmt.delta($0.faultsDelta) }))
        cols.append(.number("pageins", "Page-ins", width: 80, visible: false, help: "Pages read in from disk since the process started",
                            value: { $0.stats?.pageins ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.pageins)) } ?? "" }))
        cols.append(.number("cowFaults", "Copy-on-write faults", width: 90, visible: false,
                            help: "Copy-on-write faults (writes to shared pages, which then get copied) since the process started",
                            value: { $0.stats?.cowFaults ?? 0 }, text: { $0.stats.map { Fmt.count(Int($0.cowFaults)) } ?? "" }))

        // Disk
        cols.append(.number("diskRead", "Disk read bytes", width: 90, visible: false, help: "Bytes read from disk since the process started",
                            value: { $0.stats?.diskBytesRead ?? 0 }, text: { s($0.stats?.diskBytesRead) }))
        cols.append(.number("diskWrite", "Disk write bytes", width: 90, visible: false, help: "Bytes written to disk since the process started",
                            value: { $0.stats?.diskBytesWritten ?? 0 }, text: { s($0.stats?.diskBytesWritten) }))
        cols.append(.number("diskReadRate", "Disk read rate", width: 85, visible: false, help: "Bytes read from disk per second",
                            value: { $0.diskReadRate }, text: { Fmt.rate($0.diskReadRate) }))
        cols.append(.number("diskWriteRate", "Disk write rate", width: 85, visible: false, help: "Bytes written to disk per second",
                            value: { $0.diskWriteRate }, text: { Fmt.rate($0.diskWriteRate) }))
        cols.append(.number("logicalWrites", "Logical writes", width: 90, visible: false,
                            help: "Bytes written to files since the process started, counted as they're written rather than as they reach the disk",
                            value: { $0.stats?.logicalWrites ?? 0 }, text: { s($0.stats?.logicalWrites) }))

        // Time
        cols.append(.number("startTime", "Start time", width: 140, visible: false, help: "When the process started",
                            value: { $0.record.startMicros }, text: { Fmt.date($0.record.startTime) }))
        cols.append(.number("runningTime", "Running time", width: 100, visible: false, help: "How long the process has been running",
                            value: { -$0.record.startMicros }, text: { Fmt.relative(seconds: Date().timeIntervalSince1970 - $0.record.startTime) }))

        // Graphs
        var cpuGraph = ProcessColumn("cpuHistory", "CPU history", width: 80, visible: false,
                                     help: "CPU usage over the last 120 updates; sorts by current usage",
                                     text: { _ in "" }, less: { $0.cpu < $1.cpu })
        cpuGraph.kind = .graph
        cpuGraph.graph = { GraphCellData(values: $0.cpuHistory.ordered, maxValue: 100, color: .systemGreen) }
        cols.append(cpuGraph)
        var memGraph = ProcessColumn("memoryHistory", "Memory history", width: 80, visible: false,
                                     help: "Memory footprint over the last 120 updates; sorts by current footprint",
                                     text: { _ in "" },
                                     less: { ($0.stats?.physFootprint ?? 0) < ($1.stats?.physFootprint ?? 0) })
        memGraph.kind = .graph
        memGraph.graph = { GraphCellData(values: $0.memoryHistory.ordered, maxValue: max(1, $0.memoryHistory.maxValue), color: .systemOrange) }
        cols.append(memGraph)
        var ioGraph = ProcessColumn("ioHistory", "Disk history", width: 80, visible: false,
                                    help: "Disk read + write rate over the last 120 updates; sorts by current rate",
                                    text: { _ in "" },
                                    less: { $0.ioTotalRate < $1.ioTotalRate })
        ioGraph.kind = .graph
        ioGraph.graph = { GraphCellData(values: $0.ioHistory.ordered, maxValue: max(1, $0.ioHistory.maxValue), color: .systemBlue) }
        cols.append(ioGraph)
        var gpuGraph = ProcessColumn("gpuHistory", "GPU history", width: 80, visible: false,
                                     help: "GPU usage over the last 120 updates; sorts by current usage",
                                     text: { _ in "" }, less: { $0.gpu < $1.gpu })
        gpuGraph.kind = .graph
        gpuGraph.graph = { GraphCellData(values: $0.gpuHistory.ordered, maxValue: 100, color: .systemIndigo) }
        cols.append(gpuGraph)
        var netGraph = ProcessColumn("netHistory", "Network history", width: 80, visible: false,
                                     help: "Network receive + send rate over the last 120 updates; sorts by current rate",
                                     text: { _ in "" },
                                     less: { $0.netTotalRate < $1.netTotalRate })
        netGraph.kind = .graph
        netGraph.graph = { GraphCellData(values: $0.netHistory.ordered, maxValue: max(1, $0.netHistory.maxValue), color: .systemTeal) }
        cols.append(netGraph)

        return cols
    }

    /// The distinct types of the assertions that are on.
    private static func assertionTypes(_ p: ProcessItem) -> String {
        guard !p.assertions.isEmpty else { return "" }
        var seen = Set<String>()
        return p.assertions.filter { $0.isOn && seen.insert($0.type).inserted }.map(\.type).joined(separator: ", ")
    }

    private static func respondingText(_ p: ProcessItem) -> String {
        switch p.responding {
        case true?: return "Yes"
        case false?:
            let since = p.notRespondingSince.map { Fmt.relative(seconds: Date().timeIntervalSince($0)) }
            return since.map { "Not responding (\($0))" } ?? "Not responding"
        case nil: return ""
        }
    }

    private static func s(_ v: UInt64?) -> String {
        guard let v, v > 0 else { return "" }
        return Fmt.bytes(v)
    }

    /// "↓ 1.4 MB/s  ↑ 56 KB/s" with colored arrows, or empty when there's no traffic.
    private static func networkRate(_ p: ProcessItem) -> NSAttributedString {
        let text = NSMutableAttributedString()
        guard p.netInRate > 0 || p.netOutRate > 0 else { return text }
        func part(_ arrow: String, _ color: NSColor, _ rate: Double) {
            text.append(NSAttributedString(string: arrow + " ", attributes: [.foregroundColor: color]))
            text.append(NSAttributedString(string: Fmt.rate(rate).ifEmpty("0 B/s")))
        }
        part("↓", .systemCyan, p.netInRate)
        text.append(NSAttributedString(string: "  "))
        part("↑", .systemRed, p.netOutRate)
        return text
    }

    /// A CPU percentage as `Fmt.percent` shows it, with the "<" of "< 0.01" in the CPU graph's green
    /// so a barely busy process stands apart from one at 0.01.
    static func cpuPercent(_ percent: Double) -> NSAttributedString {
        let text = Fmt.percent(percent)
        guard text.hasPrefix("<") else { return NSAttributedString(string: text) }
        let styled = NSMutableAttributedString(string: text)
        styled.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: NSRange(location: 0, length: 1))
        return styled
    }

    /// A percentage as displayed (two decimals), for sorting: rows that show the same value tie
    /// and keep a stable order, instead of trading places every refresh over digits nobody sees,
    /// which also moved and redrew rows for nothing.
    private static func shown(_ percent: Double) -> Double {
        (percent * 100).rounded()
    }

    private static func c(_ v: UInt64?) -> String {
        guard let v, v > 0 else { return "" }
        return Fmt.count(v)
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
}
