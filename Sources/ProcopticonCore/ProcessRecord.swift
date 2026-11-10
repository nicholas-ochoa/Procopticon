import CSysInfo
import Foundation

/// Uniquely identifies a process instance (pid + start time guards against pid reuse).
public struct ProcessKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var pid: Int32
    public var startMicros: Int64

    public init(pid: Int32, startMicros: Int64) {
        self.pid = pid
        self.startMicros = startMicros
    }

    public var description: String { "\(pid)@\(startMicros)" }

    /// The process that has `pid` now, or nil when none does.
    public static func current(pid: Int32) -> ProcessKey? {
        var start: Int64 = 0
        guard si_pid_start_micros(pid, &start) == 0 else { return nil }
        return ProcessKey(pid: pid, startMicros: start)
    }

    /// Whether this process is still running: its PID exists and hasn't been reused since.
    public var isRunning: Bool { ProcessKey.current(pid: pid) == self }
}

public struct TaskStats: Codable, Sendable {
    public var hasTaskInfo: Bool
    public var hasRusage: Bool
    public var virtualSize: UInt64
    public var residentSize: UInt64
    public var userTimeNs: UInt64
    public var systemTimeNs: UInt64
    public var threadCount: Int32
    public var runningThreads: Int32
    public var priority: Int32
    public var faults: Int32
    public var pageins: Int32
    public var cowFaults: Int32
    public var messagesSent: Int32
    public var messagesReceived: Int32
    public var syscallsMach: Int32
    public var syscallsUnix: Int32
    public var contextSwitches: Int32
    public var physFootprint: UInt64
    public var lifetimeMaxFootprint: UInt64
    public var wiredSize: UInt64
    public var diskBytesRead: UInt64
    public var diskBytesWritten: UInt64
    public var logicalWrites: UInt64
    public var instructions: UInt64
    public var cycles: UInt64
    public var energyNj: UInt64
    public var billedEnergy: UInt64
    public var idleWakeups: UInt64
    public var interruptWakeups: UInt64
    public var runnableTimeNs: UInt64
    public var neuralFootprint: UInt64
    public var pcpuInstructions: UInt64
    public var pcpuCycles: UInt64
    public var pTimeNs: UInt64
    /// Bytes of the process's memory held compressed (nil when its task couldn't be inspected).
    public var compressed: UInt64?
    /// Volatile purgeable memory: caches the system may discard under memory pressure.
    public var purgeable: UInt64?

    init(_ s: si_task_stats) {
        hasTaskInfo = s.hasTaskInfo != 0
        hasRusage = s.hasRusage != 0
        virtualSize = s.virtualSize
        residentSize = s.residentSize
        userTimeNs = s.userTimeNs
        systemTimeNs = s.systemTimeNs
        threadCount = s.threadCount
        runningThreads = s.runningThreads
        priority = s.priority
        faults = s.faults
        pageins = s.pageins
        cowFaults = s.cowFaults
        messagesSent = s.messagesSent
        messagesReceived = s.messagesReceived
        syscallsMach = s.syscallsMach
        syscallsUnix = s.syscallsUnix
        contextSwitches = s.contextSwitches
        physFootprint = s.physFootprint
        lifetimeMaxFootprint = s.lifetimeMaxFootprint
        wiredSize = s.wiredSize
        diskBytesRead = s.diskBytesRead
        diskBytesWritten = s.diskBytesWritten
        logicalWrites = s.logicalWrites
        instructions = s.instructions
        cycles = s.cycles
        energyNj = s.energyNj
        billedEnergy = s.billedEnergy
        idleWakeups = s.idleWakeups
        interruptWakeups = s.interruptWakeups
        runnableTimeNs = s.runnableTimeNs
        neuralFootprint = s.neuralFootprint
        pcpuInstructions = s.pcpuInstructions
        pcpuCycles = s.pcpuCycles
        pTimeNs = s.pTimeNs
        compressed = s.hasVmInfo != 0 ? s.compressed : nil
        purgeable = s.hasVmInfo != 0 ? s.purgeableVolatile : nil
    }

    public var totalTimeNs: UInt64 { userTimeNs &+ systemTimeNs }
    public var syscalls: Int64 { Int64(syscallsMach) + Int64(syscallsUnix) }
    public var wakeups: UInt64 { idleWakeups &+ interruptWakeups }
}

/// Raw per-process sample. Produced either in-process or by the privileged helper.
public struct ProcessRecord: Codable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    public var uid: UInt32
    public var ruid: UInt32
    public var rgid: UInt32
    public var svuid: UInt32
    public var status: Int32
    public var flags: UInt32
    public var nice: Int32
    public var tty: Int32
    public var startMicros: Int64
    public var comm: String
    public var path: String?
    public var arguments: [String]?
    /// The title the process gave itself, if any; see `customTitle(arguments:path:comm:)`.
    public var title: String?
    /// For a retitled process, its arguments as read before it set the title (when Procopticon saw
    /// it start); retitling overwrites them in the process.
    public var launchArguments: [String]?
    public var stats: TaskStats?
    public var fdCount: Int32?
    public var csFlags: UInt32?
    public var sandboxed: Bool?
    public var responsiblePid: Int32?
    /// The jetsam band: under memory pressure, lower bands are killed first (root only).
    public var jetsamPriority: Int32?
    /// The memory footprint jetsam kills the process beyond, in MB; -1 for none (root only).
    public var memoryLimitMB: Int32?

    public var key: ProcessKey { ProcessKey(pid: pid, startMicros: startMicros) }
    public var startTime: Double { Double(startMicros) / 1_000_000 }

    /// Best display name: executable file name (comm is truncated to 16 chars).
    public var name: String {
        if let path, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if pid == 0 {
            return "kernel_task"
        }
        return comm
    }

    /// The command line as launched. For a process that replaced argv[0] with a title, this is the
    /// command line from before the title when it was seen, otherwise the executable followed by
    /// whatever arguments the title left in place.
    public var commandLine: String? {
        commandLineArguments?.shellJoined
    }

    /// The arguments `commandLine` joins.
    public var commandLineArguments: [String]? {
        guard let arguments, !arguments.isEmpty else {
            return nil
        }
        guard title != nil else {
            return arguments
        }
        if let launchArguments, !launchArguments.isEmpty {
            return launchArguments
        }
        guard let path else {
            return arguments
        }
        return [path] + survivingArguments
    }

    /// True when the process overwrote its arguments with its title and they weren't seen before,
    /// so `commandLine` can only show the executable.
    public var argumentsOverwritten: Bool {
        guard title != nil, launchArguments == nil, let arguments, arguments.count > 1 else {
            return false
        }
        return survivingArguments.isEmpty
    }

    /// Arguments after argv[0], minus the empty ones a retitle leaves at the end.
    private var survivingArguments: [String] {
        Array((arguments ?? []).dropFirst().reversed().drop(while: \.isEmpty).reversed())
    }

    /// The title a process gave itself by overwriting argv[0] (setproctitle, Node's `process.title`,
    /// "postgres: checkpointer"), or nil when argv[0] is just how the process was started: the
    /// executable's path or name, a symlink or version-manager shim with the same name, another
    /// existing file, or a command on the usual PATH. A login shell's leading "-" is ignored.
    public static func customTitle(arguments: [String], path: String?, comm: String) -> String? {
        guard let original = arguments.first, let path, !path.isEmpty else {
            return nil
        }
        var first = original
        if first.hasPrefix("-") {
            first.removeFirst()
        }
        while first.hasPrefix("./") {
            first.removeFirst(2)
        }
        guard !first.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        let name = (first as NSString).lastPathComponent
        if first == path || name == (path as NSString).lastPathComponent {
            return nil
        }
        // comm is the name of the file that was executed, cut to 16 bytes.
        if !comm.isEmpty, name == comm || (comm.utf8.count >= 15 && name.hasPrefix(comm)) {
            return nil
        }
        if first.contains("/") {
            if first.hasPrefix("/"), FileManager.default.fileExists(atPath: first) {
                return nil
            }
        } else if commandDirectories.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/" + first) }) {
            return nil
        }
        return original.trimmingCharacters(in: .whitespaces)
    }

    /// Where a bare command name in argv[0] would usually have been found.
    private static let commandDirectories: [String] = {
        let standard = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin"]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (path + standard).filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    public var isTranslated: Bool { flags & 0x0002_0000 != 0 }   // P_TRANSLATED
    public var isTraced: Bool { flags & 0x0000_0800 != 0 }       // P_TRACED
    public var isStopped: Bool { status == 4 }                    // SSTOP
    public var isZombie: Bool { status == 5 }                     // SZOMB
    public var is64Bit: Bool { flags & 0x0000_0004 != 0 }        // P_LP64
    public var isElevated: Bool { uid == 0 && ruid != 0 }          // setuid/sudo style elevation

    public var stateDescription: String {
        switch status {
        case 1: return "Idle"
        case 2: return "Running"
        case 3: return "Sleeping"
        case 4: return "Stopped"
        case 5: return "Zombie"
        default: return "Unknown"
        }
    }

    public var architecture: String {
        if pid == 0 {
            return ""
        }
        #if arch(arm64)
        return isTranslated ? "x86_64 (Rosetta)" : (is64Bit ? "arm64" : "32-bit")
        #else
        return is64Bit ? "x86_64" : "i386"
        #endif
    }

    public var ttyName: String? {
        guard tty != -1, let name = devname(dev_t(tty), S_IFCHR) else {
            return nil
        }
        return String(cString: name)
    }
}

public struct CodeSigningFlags {
    public static let valid: UInt32 = 0x0000_0001
    public static let adhoc: UInt32 = 0x0000_0002
    public static let getTaskAllow: UInt32 = 0x0000_0004
    public static let installer: UInt32 = 0x0000_0008
    public static let forcedLibraryValidation: UInt32 = 0x0000_0010
    public static let invalidAllowed: UInt32 = 0x0000_0020
    public static let hard: UInt32 = 0x0000_0100
    public static let kill: UInt32 = 0x0000_0200
    public static let checkExpiration: UInt32 = 0x0000_0400
    public static let restrict: UInt32 = 0x0000_0800
    public static let enforcement: UInt32 = 0x0000_1000
    public static let requireLV: UInt32 = 0x0000_2000
    public static let entitlementsValidated: UInt32 = 0x0000_4000
    public static let runtime: UInt32 = 0x0001_0000
    public static let linkerSigned: UInt32 = 0x0002_0000
    public static let execSetHard: UInt32 = 0x0010_0000
    public static let execSetKill: UInt32 = 0x0020_0000
    public static let execSetEnforcement: UInt32 = 0x0040_0000
    public static let signed: UInt32 = 0x2000_0000
    public static let platformBinary: UInt32 = 0x0400_0000
    public static let debugged: UInt32 = 0x1000_0000
    public static let devCode: UInt32 = 0x0000_8000

    public static func describe(_ flags: UInt32) -> [String] {
        let table: [(UInt32, String)] = [
            (valid, "Valid"), (adhoc, "Ad-hoc signed"), (getTaskAllow, "Get-task-allow (debuggable)"),
            (installer, "Installer"), (forcedLibraryValidation, "Forced library validation"),
            (invalidAllowed, "Invalid pages allowed"), (hard, "Hard"), (kill, "Kill on invalid"),
            (checkExpiration, "Check expiration"), (restrict, "Restrict"), (enforcement, "Enforcement"),
            (requireLV, "Library validation"), (entitlementsValidated, "Entitlements validated"),
            (devCode, "Development code"), (runtime, "Hardened runtime"), (linkerSigned, "Linker signed"),
            (platformBinary, "Platform binary"), (debugged, "Debugged"), (signed, "Signed"),
        ]
        return table.filter { flags & $0.0 != 0 }.map(\.1)
    }
}
