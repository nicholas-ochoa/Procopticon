import CSysInfo
import Darwin
import Foundation

/// Operations that may require root. Executed in-process when running as root, otherwise by the
/// privileged helper (or locally without elevation, for the caller's own processes).
public enum PrivilegedRequest: Codable, Sendable {
    case ping
    case sampleProcesses
    /// `startMicros` is the start time of the process the caller means (`ProcessKey.startMicros`):
    /// when given, the request is refused if the PID now belongs to a different process.
    case signal(pid: Int32, signal: Int32, startMicros: Int64?)
    case setPriority(pid: Int32, nice: Int32, startMicros: Int64?)
    case setBackground(pid: Int32, enabled: Bool, startMicros: Int64?)
    case fileDescriptors(pid: Int32)
    case threads(pid: Int32)
    case regions(pid: Int32)
    case arguments(pid: Int32)
    case workingDirectory(pid: Int32)
    case connections
    case searchOpenFiles(query: String, includeLibraries: Bool, regex: Bool)
    case runTool(tool: String, arguments: [String])
    /// Runs a tool that writes a report to a file, and answers with the report. The argument
    /// equal to `ToolReport.placeholder` becomes the file's path; see `ToolReport`.
    case runToolReport(tool: String, arguments: [String])
    case launch(path: String, arguments: [String])
    /// Starts a long-running tool whose output is read with `readStream`; see `ToolStream`.
    case startStream(tool: String, arguments: [String])
    case readStream(id: Int)
    case stopStream(id: Int)
    /// Login items, extensions, cron jobs and the like; see `StartupItems`.
    case startupItems
    /// Mach port counts of every process, or of one (root only); see `MachPorts`.
    case machPortCounts
    case machPortCount(pid: Int32)
    /// Turns a startup item off or on, or removes it; see `StartupItems.perform`.
    case startupAction(StartupAction)
    case shutdown

    /// Whether the request only reads. When the helper is gone, these are answered with the
    /// user's own privileges instead; anything that acts (signals, running a program, changing a
    /// startup item) fails, so that nothing meant to happen as root happens as the user.
    var isReadOnly: Bool {
        switch self {
        case .ping, .sampleProcesses, .fileDescriptors, .threads, .regions, .arguments, .workingDirectory,
             .connections, .searchOpenFiles, .startupItems, .machPortCounts, .machPortCount:
            return true
        case .signal, .setPriority, .setBackground, .runTool, .runToolReport, .launch, .startStream,
             .readStream, .stopStream, .startupAction, .shutdown:
            return false
        }
    }

    /// How long the helper may take to answer before the client gives up on it; generous enough
    /// for the slowest work each request does.
    var replyTimeout: TimeInterval {
        switch self {
        case .ping: return 5
        case .runTool, .runToolReport: return ToolRunner.defaultTimeout + 30
        // Several tools in turn (sfltool, kmutil, profiles, pluginkit, launchctl), up to 30 s each.
        case .startupItems: return 240
        case .startupAction: return 90
        case .regions, .connections, .searchOpenFiles, .machPortCounts: return 60
        default: return 15
        }
    }
}

public struct PrivilegedError: Error, Codable, Sendable, LocalizedError {
    public var code: Int32
    public var message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public init(errno code: Int32, context: String) {
        self.code = code
        message = "\(context): \(String(cString: strerror(code)))"
    }

    public var isPermissionDenied: Bool { code == EPERM || code == EACCES }
    public var errorDescription: String? { message }

    public static let cancelled = PrivilegedError(code: ECANCELED, message: "Authorization was cancelled.")
}

public struct ToolOutput: Codable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var combined: String {
        stderr.isEmpty ? stdout : (stdout.isEmpty ? stderr : stdout + "\n" + stderr)
    }
}

public enum PrivilegedResponse: Codable, Sendable {
    case ok
    case pong(uid: UInt32, pid: Int32)
    case failure(PrivilegedError)
    case processes([ProcessRecord])
    case fileDescriptors([FileDescriptorInfo])
    case threads([ThreadInfo])
    case regions([MemoryRegion])
    case arguments(ProcessArguments)
    case connections([NetworkConnection])
    case tool(ToolOutput)
    case launched(pid: Int32)
    case text(String)
    case openFiles([OpenFileMatch])
    case streamStarted(id: Int)
    case streamOutput(StreamChunk)
    case startupItems(StartupItemsReport)
    case portCounts([Int32: Int])

    public var error: PrivilegedError? {
        if case .failure(let e) = self { return e }
        return nil
    }

    public func check() throws {
        if let error { throw error }
    }
}

/// Command-line tools the helper is willing to run as root: those the app sends it (`runTool`,
/// `startStream`), and no more. Not a security boundary on its own; see `HelperServer`.
public enum AllowedTools {
    public static let paths: Set<String> = [
        "/usr/bin/vmmap", "/usr/bin/sample", "/bin/launchctl", "/usr/sbin/purge", "/usr/bin/heap",
        "/usr/bin/leaks", "/usr/sbin/lsof", "/usr/bin/footprint", "/usr/sbin/spindump", "/usr/bin/killall",
        "/usr/bin/dscacheutil", "/usr/bin/log", "/usr/bin/gcore", "/usr/bin/fs_usage", "/usr/bin/powermetrics",
    ]
}

public enum ToolRunner {
    public static let defaultTimeout: TimeInterval = 120
    /// The most output kept from each of a tool's streams. More is read and dropped, so the tool
    /// isn't held up; it is far below what a reply to the app may carry (`Framing`).
    static let outputLimit = 128 << 20

    private static let lock = NSLock()
    private static var running = Set<pid_t>()

    /// Ends the tools still running. For the helper as it exits: a `sample` or `spindump` it
    /// started would otherwise run on as root with nobody left to read what it writes.
    public static func terminateRunning() {
        lock.lock()
        let pids = running
        lock.unlock()
        for pid in pids {
            kill(pid, SIGTERM)
        }
    }

    /// What a tool wrote to one of its streams, up to `outputLimit`.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var dropped = false

        /// read(2) itself, which returns what there is: what was written before a tool was
        /// stopped is kept. (FileHandle's reads wait for a full buffer or the end.)
        func read(from handle: FileHandle) {
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                lock.lock()
                if data.count + count <= ToolRunner.outputLimit {
                    data.append(buffer, count: count)
                } else {
                    dropped = true
                }
                lock.unlock()
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self) + (dropped ? "\n[The rest of the output was too long and was dropped.]\n" : "")
        }
    }

    /// Runs a tool and captures output. Blocks the calling thread, for a little longer than
    /// `timeout` at most: a tool that ignores being asked to stop is killed, and one that left
    /// something else holding its output open is not waited for.
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = defaultTimeout) -> ToolOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let out = Output()
        let err = Output()
        let group = DispatchGroup()
        do {
            try process.run()
        } catch {
            return ToolOutput(status: -1, stdout: "", stderr: "Failed to launch \(path): \(error.localizedDescription)")
        }
        let pid = process.processIdentifier
        lock.lock()
        running.insert(pid)
        lock.unlock()
        defer {
            lock.lock()
            running.remove(pid)
            lock.unlock()
        }
        for (pipe, output) in [(outPipe, out), (errPipe, err)] {
            group.enter()
            DispatchQueue.global().async {
                output.read(from: pipe.fileHandleForReading)
                group.leave()
            }
        }
        func exited(within seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning, Date() < deadline {
                usleep(2_000)
            }
            return !process.isRunning
        }
        var timedOut = group.wait(timeout: .now() + timeout) == .timedOut
        // Its output ended; the tool itself normally ends with it.
        if !timedOut, !exited(within: 10) {
            timedOut = true
        }
        if timedOut {
            process.terminate()
            if !exited(within: 3) {
                kill(pid, SIGKILL)
                _ = exited(within: 2)
            }
            // Whatever it started may still hold the pipes open.
            _ = group.wait(timeout: .now() + 1)
        }
        return ToolOutput(status: process.isRunning ? -1 : process.terminationStatus, stdout: out.text, stderr: err.text)
    }
}

/// Performs privileged requests with the privileges of the current process.
public final class PrivilegedExecutor: @unchecked Sendable {
    private let samplerLock = NSLock()
    private let sampler = ProcessSampler()
    private let streams: ToolStreamSessions
    /// When true (inside the helper), any tool in the allowlist may run; otherwise anything.
    private let restrictTools: Bool

    public init(restrictTools: Bool) {
        self.restrictTools = restrictTools
        streams = ToolStreamSessions(inApp: !restrictTools)
    }

    public func handle(_ request: PrivilegedRequest) -> PrivilegedResponse {
        switch request {
        case .ping:
            return .pong(uid: geteuid(), pid: getpid())
        case .sampleProcesses:
            samplerLock.lock()
            defer { samplerLock.unlock() }
            return .processes(sampler.sample())
        case let .signal(pid, sig, start):
            guard pid > 0 else {
                return .failure(PrivilegedError(code: EINVAL, message: "Refusing to signal pid \(pid)."))
            }
            if let error = Self.checkIdentity(pid: pid, startMicros: start) { return .failure(error) }
            if kill(pid, sig) != 0 {
                return .failure(PrivilegedError(errno: errno, context: "kill(\(pid), \(sig))"))
            }
            return .ok
        case let .setPriority(pid, nice, start):
            // Pid 0 means "the calling process" to setpriority, which here is the app or the helper.
            guard pid > 0 else {
                return .failure(PrivilegedError(code: EINVAL, message: "The priority of pid \(pid) can't be changed."))
            }
            if let error = Self.checkIdentity(pid: pid, startMicros: start) { return .failure(error) }
            if setpriority(PRIO_PROCESS, id_t(pid), nice) != 0 {
                return .failure(PrivilegedError(errno: errno, context: "setpriority(\(pid), \(nice))"))
            }
            return .ok
        case let .setBackground(pid, enabled, start):
            guard pid > 0 else {
                return .failure(PrivilegedError(code: EINVAL, message: "The scheduling of pid \(pid) can't be changed."))
            }
            if let error = Self.checkIdentity(pid: pid, startMicros: start) { return .failure(error) }
            if setpriority(PRIO_DARWIN_PROCESS, id_t(pid), enabled ? PRIO_DARWIN_BG : 0) != 0 {
                return .failure(PrivilegedError(errno: errno, context: "setpriority(PRIO_DARWIN_PROCESS, \(pid))"))
            }
            return .ok
        case let .fileDescriptors(pid):
            switch ProcessDetails.fileDescriptors(pid: pid) {
            case .success(let fds): return .fileDescriptors(fds)
            case .failure(let e): return .failure(PrivilegedError(errno: e.code.rawValue, context: "File descriptors of \(pid)"))
            }
        case let .threads(pid):
            switch ProcessDetails.threads(pid: pid) {
            case .success(let t): return .threads(t)
            case .failure(let e): return .failure(PrivilegedError(errno: e.code.rawValue, context: "Threads of \(pid)"))
            }
        case let .regions(pid):
            switch IsolatedScanner.regions(pid: pid) {
            case .success(let r): return .regions(r)
            case .failure(let e): return .failure(PrivilegedError(errno: e.code.rawValue, context: "Memory regions of \(pid)"))
            }
        case let .arguments(pid):
            switch ProcessArguments.read(pid: pid) {
            case .success(let a): return .arguments(a)
            case .failure(let e):
                // KERN_PROCARGS2 reports EINVAL for processes we may not inspect.
                let code = e.code == .EINVAL ? EPERM : e.code.rawValue
                return .failure(PrivilegedError(errno: code, context: "Arguments of \(pid)"))
            }
        case let .workingDirectory(pid):
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
            let rc = si_pid_cwd(pid, &buf, Int32(buf.count))
            if rc != 0 {
                return .failure(PrivilegedError(errno: -rc, context: "Working directory of \(pid)"))
            }
            return .text(String(cString: buf))
        case .connections:
            return .connections(ProcessDetails.allConnections())
        case let .searchOpenFiles(query, includeLibraries, regex):
            return .openFiles(ProcessDetails.searchOpenFiles(query: query, includeLibraries: includeLibraries, regex: regex))
        case let .runTool(tool, arguments):
            if restrictTools, !AllowedTools.paths.contains(tool) {
                return .failure(PrivilegedError(code: EPERM, message: "\(tool) is not an allowed tool."))
            }
            return .tool(ToolRunner.run(tool, arguments))
        case let .runToolReport(tool, arguments):
            if restrictTools, !AllowedTools.paths.contains(tool) {
                return .failure(PrivilegedError(code: EPERM, message: "\(tool) is not an allowed tool."))
            }
            return .tool(ToolReport.run(tool, arguments))
        case let .launch(path, arguments):
            return launch(path: path, arguments: arguments)
        case let .startStream(tool, arguments):
            if restrictTools, !AllowedTools.paths.contains(tool) {
                return .failure(PrivilegedError(code: EPERM, message: "\(tool) is not an allowed tool."))
            }
            return streams.start(tool, arguments)
        case let .readStream(id):
            return streams.read(id)
        case let .stopStream(id):
            streams.stop(id)
            return .ok
        case .startupItems:
            return .startupItems(StartupItems.collect())
        case .machPortCounts:
            guard let counts = MachPorts.counts() else {
                return .failure(PrivilegedError(code: EPERM, message: "Counting Mach ports needs root."))
            }
            return .portCounts(counts)
        case let .startupAction(action):
            return StartupItems.perform(action)
        case let .machPortCount(pid):
            guard let count = MachPorts.count(pid: pid) else {
                return .failure(PrivilegedError(code: EPERM, message: "Counting Mach ports needs root."))
            }
            return .portCounts([pid: count])
        case .shutdown:
            streams.stopAll()
            return .ok
        }
    }

    /// Refuses to act on `pid` when it no longer belongs to the process started at `startMicros`:
    /// a process can exit and its PID be reused while a confirmation or password prompt is open.
    /// Checked immediately before acting, which leaves only a window of microseconds; macOS has no
    /// process handle to signal instead of a PID.
    static func checkIdentity(pid: Int32, startMicros: Int64?) -> PrivilegedError? {
        guard let startMicros else { return nil }
        guard let current = ProcessKey.current(pid: pid) else {
            return PrivilegedError(code: ESRCH, message: "The process has exited.")
        }
        guard current.startMicros == startMicros else {
            return PrivilegedError(code: ESRCH, message: "The process has exited, and PID \(pid) now belongs to another process, which was left alone.")
        }
        return nil
    }

    /// Stops the streaming tools this executor started (see `ToolStreamSessions.stopAll`).
    public func stopAllStreams() {
        streams.stopAll()
    }

    private func launch(path: String, arguments: [String]) -> PrivilegedResponse {
        var pid: pid_t = 0
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Only the three descriptors opened below: not the helper's socket or its connections,
        // which the program would keep open after the helper is gone.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        defer { posix_spawnattr_destroy(&attr) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        if rc != 0 {
            return .failure(PrivilegedError(errno: rc, context: "Launching \(path)"))
        }
        // Reap asynchronously so the child doesn't linger as a zombie.
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return .launched(pid: pid)
    }
}
