import Darwin
import Foundation

/// Output a streaming tool produced since the last read.
public struct StreamChunk: Codable, Sendable {
    /// Complete lines only (a partial last line waits for the next read), unless finished.
    public var text: String
    /// The tool exited and everything it wrote has been read.
    public var finished: Bool
    public var status: Int32
    /// What the tool wrote to standard error, delivered with the final chunk.
    public var errorOutput: String
    /// Bytes thrown away because the reader didn't keep up.
    public var dropped: Int
}

/// Long-running tools (log stream, fs_usage, powermetrics) whose output is read in pieces. They run
/// wherever requests run (in-process, or in the root helper); see `ToolStream` for the client.
final class ToolStreamSessions: @unchecked Sendable {
    /// Output kept for a reader that falls behind; older output is dropped beyond it.
    static let bufferLimit = 4 << 20
    /// Output handed over by one read, so a single reply stays small.
    static let readLimit = 1 << 20
    /// A session nobody has read for this long is stopped (its reader went away).
    static let abandonAfter: TimeInterval = 60

    private final class Session {
        let process = Process()
        var output = Data()
        var errorOutput = Data()
        var dropped = 0
        var outputClosed = false
        var terminated = false
        var lastRead = Date()
    }

    private let lock = NSLock()
    private var sessions: [Int: Session] = [:]
    private var nextId = 1

    func start(_ tool: String, _ arguments: [String]) -> PrivilegedResponse {
        sweep()
        let session = Session()
        let process = session.process
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.received(data, session, isError: false)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.received(data, session, isError: true)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] _ in
            self?.lock.withLock { session.terminated = true }
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return .failure(PrivilegedError(code: ENOENT, message: "Failed to launch \(tool): \(error.localizedDescription)"))
        }
        let id: Int = lock.withLock {
            let id = nextId
            nextId += 1
            sessions[id] = session
            return id
        }
        return .streamStarted(id: id)
    }

    private func received(_ data: Data, _ session: Session, isError: Bool) {
        lock.withLock {
            if isError {
                if data.isEmpty { return }
                if session.errorOutput.count < 64 * 1024 {
                    session.errorOutput.append(data)
                }
                return
            }
            guard !data.isEmpty else {
                session.outputClosed = true
                return
            }
            session.output.append(data)
            if session.output.count > Self.bufferLimit {
                // Drop the oldest output, up to a line boundary.
                var cut = session.output.count - Self.bufferLimit / 2
                if let newline = session.output[(session.output.startIndex + cut)...].firstIndex(of: 0x0A) {
                    cut = newline - session.output.startIndex + 1
                }
                session.dropped += cut
                session.output.removeFirst(cut)
            }
        }
    }

    func read(_ id: Int) -> PrivilegedResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[id] else {
            return .failure(PrivilegedError(code: ENOENT, message: "The stream has ended."))
        }
        session.lastRead = Date()
        let done = session.terminated && session.outputClosed
        var take = session.output.count
        if take > Self.readLimit {
            take = Self.readLimit
        }
        if !done || take < session.output.count {
            // Whole lines only, so a UTF-8 sequence or JSON object is never split between reads.
            let window = session.output.prefix(take)
            take = window.lastIndex(of: 0x0A).map { $0 - session.output.startIndex + 1 } ?? 0
        }
        let text = String(decoding: session.output.prefix(take), as: UTF8.self)
        session.output.removeFirst(take)
        let finished = done && session.output.isEmpty
        let chunk = StreamChunk(text: text, finished: finished, status: finished ? session.process.terminationStatus : 0,
                                errorOutput: finished ? String(decoding: session.errorOutput, as: UTF8.self) : "",
                                dropped: session.dropped)
        session.dropped = 0
        if finished {
            sessions.removeValue(forKey: id)
        }
        return .streamOutput(chunk)
    }

    func stop(_ id: Int) {
        let session = lock.withLock { sessions.removeValue(forKey: id) }
        guard let session, session.process.isRunning else { return }
        // SIGINT, as Ctrl-C would: fs_usage and powermetrics clean up their tracing on it.
        session.process.interrupt()
        let process = session.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
    }

    /// Interrupts every tool, for when the process serving them is about to exit: they would
    /// otherwise outlive it until their next write.
    func stopAll() {
        let all = lock.withLock {
            defer { sessions.removeAll() }
            return Array(sessions.values)
        }
        for session in all where session.process.isRunning {
            session.process.interrupt()
        }
    }

    private func sweep() {
        let stale = lock.withLock {
            sessions.filter { Date().timeIntervalSince($0.value.lastRead) > Self.abandonAfter }.map(\.key)
        }
        stale.forEach(stop)
    }
}

/// Runs a long-lived tool through `Elevation` (so as root when elevated) and delivers its output
/// line by line on the main thread until it exits or `stop()` is called.
public final class ToolStream: @unchecked Sendable {
    public enum Event {
        case lines([String])
        /// Lines were lost because they came faster than they were read.
        case dropped(bytes: Int)
        case finished(status: Int32, errorOutput: String)
    }

    public let tool: String
    public let arguments: [String]
    private let lock = NSLock()
    private var id: Int?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var partial = ""
    private let queue = DispatchQueue(label: "tool-stream", qos: .utility)

    public init(tool: String, arguments: [String]) {
        self.tool = tool
        self.arguments = arguments
    }

    deinit {
        stop()
    }

    /// Starts the tool. With `requiresRoot`, asks for administrator rights first if not elevated
    /// (unless `prompt` is false). Returns the error when it couldn't start.
    public func start(requiresRoot: Bool = false, prompt: Bool = true, interval: TimeInterval = 0.3,
                      handler: @escaping @MainActor (Event) -> Void) async -> PrivilegedError? {
        let response = await Elevation.shared.performElevated(.startStream(tool: tool, arguments: arguments),
                                                              requiresRoot: requiresRoot, prompt: prompt)
        guard case .streamStarted(let id) = response else {
            return response.error ?? PrivilegedError(code: EIO, message: "\(tool) didn't start.")
        }
        let cancelled: Bool = lock.withLock {
            self.id = id
            return stopped
        }
        if cancelled {
            _ = Elevation.shared.perform(.stopStream(id: id))
            return nil
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll(id, handler: handler) }
        lock.withLock { self.timer = timer }
        timer.resume()
        return nil
    }

    private func poll(_ id: Int, handler: @escaping @MainActor (Event) -> Void) {
        var events: [Event] = []
        var finished = false
        switch Elevation.shared.perform(.readStream(id: id)) {
        case .streamOutput(let chunk):
            if chunk.dropped > 0 {
                events.append(.dropped(bytes: chunk.dropped))
            }
            var text = partial + chunk.text
            partial = ""
            if !chunk.finished, let last = text.lastIndex(of: "\n") {
                partial = String(text[text.index(after: last)...])
                text = String(text[...last])
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if !lines.isEmpty {
                events.append(.lines(lines))
            }
            if chunk.finished {
                events.append(.finished(status: chunk.status, errorOutput: chunk.errorOutput))
                finished = true
            }
        case .failure(let error):
            events.append(.finished(status: -1, errorOutput: error.message))
            finished = true
        default:
            break
        }
        if finished {
            lock.withLock {
                timer?.cancel()
                timer = nil
                self.id = nil
            }
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async {
            guard !self.isStopped else { return }
            for event in events {
                MainActor.assumeIsolated { handler(event) }
            }
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    public func stop() {
        let id: Int? = lock.withLock {
            stopped = true
            timer?.cancel()
            timer = nil
            defer { self.id = nil }
            return self.id
        }
        if let id {
            DispatchQueue.global(qos: .utility).async {
                _ = Elevation.shared.perform(.stopStream(id: id))
            }
        }
    }
}
