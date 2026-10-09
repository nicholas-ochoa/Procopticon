import Foundation
import ProcopticonCore

public typealias ProcessExpressionEngine = ExpressionEngine<ProcessItem>

extension ExpressionEngine where Row == ProcessItem {
    /// An engine for expressions over processes, with their fields (`ProcessExpressions.fields`).
    public convenience init() {
        self.init(fields: ProcessExpressions.fields, prelude: ProcessExpressions.prelude)
    }
}

extension ExpressionEngine: ProcessExpressionCompiler where Row == ProcessItem {
    public func compileProcessExpression(_ source: String) -> any CompiledProcessExpression {
        compile(source)
    }
}

extension CompiledExpression: CompiledProcessExpression where Row == ProcessItem {}

/// The values of a process that expressions use, and what else they can use.
extension ProcessExpressions {
    /// Units for byte counts, as the app shows them (1 KB = 1024 bytes).
    static let prelude = """
        Object.defineProperties(globalThis, {
            KB: { value: 1024 }, MB: { value: 1024 ** 2 }, GB: { value: 1024 ** 3 }, TB: { value: 1024 ** 4 },
        });
        """

    public static let constants: [(name: String, help: String)] = [
        ("KB, MB, GB, TB", "Byte units (1 KB = 1024 bytes): memory > 2 * GB"),
    ]

    public static let examples: [(expression: String, help: String)] = [
        ("cpu > 50 && memory > 2 * GB", "busy and large"),
        ("user == \"root\" && !appleSigned", "root processes not signed by Apple"),
        ("/helper/i.test(name) && age < 60", "helpers started in the last minute"),
        ("args.includes(\"--headless\")", "started with an argument"),
        ("path.startsWith(\"/Applications/\") && threads > 100", "apps with many threads"),
    ]

    public static let fields: [ExpressionField<ProcessItem>] = {
        typealias Field = ExpressionField<ProcessItem>
        func number(_ v: some BinaryInteger) -> ExpressionValue { .number(Double(v)) }
        func maybe(_ v: (some BinaryInteger)?) -> ExpressionValue { v.map { .number(Double($0)) } ?? .null }
        func seconds(_ ns: UInt64?) -> ExpressionValue { ns.map { .number(Double($0) / 1e9) } ?? .null }
        func text(_ s: String?) -> ExpressionValue { .string(s ?? "") }
        func flag(_ b: Bool?) -> ExpressionValue { b.map { .bool($0) } ?? .null }
        func signingFlag(_ p: ProcessItem, _ mask: UInt32) -> ExpressionValue {
            flag(p.record.csFlags.map { $0 & mask != 0 })
        }
        return [
            // Identity
            Field("pid", .number, "Process ID") { number($0.pid) },
            Field("ppid", .number, "Parent process ID") { number($0.record.ppid) },
            Field("pgid", .number, "Process group ID") { number($0.record.pgid) },
            Field("responsiblePid", .number,
                  "The process macOS holds responsible for this one, e.g. the app that started an XPC service; null if none") {
                maybe($0.record.responsiblePid)
            },
            Field("name", .string, "The name in the Name column: an app's name for its main executable, otherwise the executable's") {
                text($0.displayName)
            },
            Field("executable", .string, "The executable's file name") { text($0.name) },
            Field("path", .string, "Full path of the executable") { text($0.record.path) },
            Field("commandLine", .string, "The command line it was started with") { text($0.record.commandLine) },
            Field("args", .strings, "The arguments it was started with, starting with the command") {
                .strings($0.record.commandLineArguments ?? [])
            },
            Field("title", .string, "The title the process gave itself in place of its command line") { text($0.record.title) },
            Field("description", .string, "The app's or bundle's display name") { text($0.displayDescription) },
            Field("user", .string, "The user it runs as") { text($0.userName) },
            Field("uid", .number, "The ID of the user it runs as (0 is root)") { number($0.record.uid) },
            Field("realUser", .string, "The user who started it; differs from user for setuid programs") {
                text(UserNames.name($0.record.ruid))
            },
            Field("group", .string, "Its group") { text(UserNames.group($0.record.rgid)) },
            Field("bundleId", .string, "Bundle identifier of the app or bundle it's in") { text($0.bundleInfo?.bundleIdentifier) },
            Field("version", .string, "Version of the app or bundle it's in") { text($0.bundleInfo?.versionString) },
            Field("company", .string, "Organization from the code signing certificate; empty until the signature has been checked") {
                text($0.signing?.organization)
            },
            Field("teamId", .string, "Apple Developer Team ID from the code signature") { text($0.signing?.teamIdentifier) },
            Field("arch", .string, "arm64, or x86_64 (Rosetta)") { text($0.record.architecture) },
            Field("tty", .string, "Controlling terminal, e.g. ttys003") { text($0.record.ttyName) },
            Field("state", .string, "Running, Sleeping, Idle, Stopped or Zombie") { text($0.record.stateDescription) },

            // Resource use
            Field("cpu", .number, "CPU usage in percent, as the CPU column shows it") { .number($0.cpu) },
            Field("cpuUser", .number, "CPU usage running its own code, in percent") { .number($0.cpuUser) },
            Field("cpuKernel", .number, "CPU usage in the kernel on its behalf, in percent") { .number($0.cpuKernel) },
            Field("cpuTime", .number, "CPU time used since it started, in seconds") { seconds($0.stats?.totalTimeNs) },
            Field("memory", .number, "Memory footprint in bytes, as in the Memory column") { maybe($0.stats?.physFootprint) },
            Field("peakMemory", .number, "Highest memory footprint since it started, in bytes") {
                maybe($0.stats?.lifetimeMaxFootprint)
            },
            Field("resident", .number, "Resident size in bytes") { maybe($0.stats?.residentSize) },
            Field("virtualSize", .number, "Virtual size in bytes") { maybe($0.stats?.virtualSize) },
            Field("wired", .number, "Wired memory in bytes") { maybe($0.stats?.wiredSize) },
            Field("compressed", .number, "Compressed memory in bytes") { maybe($0.stats?.compressed) },
            Field("purgeable", .number, "Purgeable memory in bytes") { maybe($0.stats?.purgeable) },
            Field("memoryLimit", .number, "The footprint in bytes at which the system kills it (jetsam limit); null if none or unknown") { p in
                guard let mb = p.record.memoryLimitMB, mb >= 0 else { return .null }
                return .number(Double(mb) * 1024 * 1024)
            },
            Field("jetsamPriority", .number, "Jetsam band; lower bands are killed first under memory pressure") {
                maybe($0.record.jetsamPriority)
            },
            Field("gpu", .number, "GPU usage in percent") { .number($0.gpu) },
            Field("diskRate", .number, "Disk read + write bytes per second") { .number($0.ioTotalRate) },
            Field("diskReadRate", .number, "Disk bytes read per second") { .number($0.diskReadRate) },
            Field("diskWriteRate", .number, "Disk bytes written per second") { .number($0.diskWriteRate) },
            Field("diskRead", .number, "Disk bytes read since it started") { maybe($0.stats?.diskBytesRead) },
            Field("diskWrite", .number, "Disk bytes written since it started") { maybe($0.stats?.diskBytesWritten) },
            Field("netRate", .number, "Network receive + send bytes per second") { .number($0.netTotalRate) },
            Field("netInRate", .number, "Network bytes received per second") { .number($0.netInRate) },
            Field("netOutRate", .number, "Network bytes sent per second") { .number($0.netOutRate) },
            Field("netIn", .number, "Network bytes received") { maybe($0.network?.bytesIn) },
            Field("netOut", .number, "Network bytes sent") { maybe($0.network?.bytesOut) },
            Field("threads", .number, "Number of threads") { maybe($0.stats?.threadCount) },
            Field("runningThreads", .number, "Threads running or ready to run") { maybe($0.stats?.runningThreads) },
            Field("fds", .number, "Open file descriptors") { maybe($0.record.fdCount) },
            Field("ports", .number, "Mach ports it holds, while the Ports column counts them; otherwise null") { maybe($0.machPorts) },
            Field("priority", .number, "Base scheduling priority") { maybe($0.stats?.priority) },
            Field("nice", .number, "Nice value, from −20 to 20") { number($0.record.nice) },
            Field("power", .number, "Estimated power draw in watts") { .number($0.power) },
            Field("age", .number, "Seconds since it started") { .number(Date().timeIntervalSince1970 - $0.record.startTime) },
            Field("startTime", .date, "When it started") { .date(Date(timeIntervalSince1970: $0.record.startTime)) },

            // State
            Field("app", .boolean, "Part of an application bundle") { .bool($0.bundleInfo?.isApplication == true) },
            Field("mine", .boolean, "Runs as you") { .bool($0.record.uid == Elevation.interactiveUid) },
            Field("exited", .boolean, "Has exited (it stays listed for a moment)") { .bool($0.isRemoved) },
            Field("notResponding", .boolean, "An application that isn't responding (the spinning wait cursor)") {
                .bool($0.isNotResponding)
            },
            Field("preventingSleep", .boolean, "Keeps the Mac or its display awake") { .bool($0.sleepPrevention != nil) },
            Field("microphone", .boolean, "Using the microphone") { .bool($0.sensors.contains(.microphone)) },
            Field("camera", .boolean, "Using the camera") { .bool($0.sensors.contains(.camera)) },
            Field("screenRecording", .boolean, "Recording the screen") { .bool($0.sensors.contains(.screenRecording)) },
            Field("stopped", .boolean, "Stopped (suspended)") { .bool($0.record.isStopped) },
            Field("zombie", .boolean, "A zombie: exited, but its parent hasn't collected it") { .bool($0.record.isZombie) },
            Field("traced", .boolean, "Being traced or debugged") { .bool($0.record.isTraced) },
            Field("translated", .boolean, "Running under Rosetta") { .bool($0.record.isTranslated) },
            Field("elevated", .boolean, "Runs as root but was started by another user (setuid or sudo)") { .bool($0.record.isElevated) },
            Field("sandboxed", .boolean, "In the App Sandbox; null if unknown") { flag($0.record.sandboxed) },
            Field("signed", .boolean, "Has a valid code signature; null if unknown") { p in
                flag(p.record.csFlags.map { $0 & CodeSigningFlags.valid != 0 && $0 & CodeSigningFlags.signed != 0 })
            },
            Field("appleSigned", .boolean, "Signed by Apple; null until the signature has been checked") {
                flag($0.signing?.isAppleSigned)
            },
            Field("platformBinary", .boolean, "An Apple platform binary (part of macOS); null if unknown") {
                signingFlag($0, CodeSigningFlags.platformBinary)
            },
            Field("hardenedRuntime", .boolean, "Signed with the hardened runtime; null if unknown") {
                signingFlag($0, CodeSigningFlags.runtime)
            },
            Field("quarantined", .boolean, "Downloaded from the internet (quarantined)") { .bool($0.bundleInfo?.quarantine != nil) },
        ]
    }()
}
