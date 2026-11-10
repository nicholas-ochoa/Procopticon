import Darwin
import Foundation
import SystemConfiguration

/// Central broker for privileged operations.
///
/// * **Root ("sudo") mode** — the app itself runs with euid 0 (e.g. `sudo Procopticon`), so every
///   request executes in-process and the user is never prompted.
/// * **Helper mode** — the user authorized once; a root helper serves requests over a Unix socket
///   that only this app process may connect to.
/// * **Standard mode** — requests execute with the user's own privileges. When one fails with a
///   permission error, callers may opt in to prompting, which starts the helper and retries.
public final class Elevation: @unchecked Sendable {
    public static let shared = Elevation()
    public static let didChangeNotification = Notification.Name("Procopticon.ElevationDidChange")

    public enum Mode: String, Sendable {
        case root = "Root"
        case helper = "Elevated helper"
        case standard = "Standard"
    }

    private let lock = NSLock()
    private let local = PrivilegedExecutor(restrictTools: false)
    private var client: HelperClient?
    private var launching = false

    public var mode: Mode {
        if geteuid() == 0 { return .root }
        lock.lock()
        defer { lock.unlock() }
        return client != nil ? .helper : .standard
    }

    public var isElevated: Bool { mode != .standard }

    /// The interactive user: SUDO_UID when started via sudo, otherwise the real uid.
    public static let interactiveUid: uid_t = {
        if geteuid() == 0 {
            if let s = ProcessInfo.processInfo.environment["SUDO_UID"], let v = uid_t(s) {
                return v
            }
            var uid: uid_t = 0
            if let _ = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) {
                return uid
            }
        }
        return getuid()
    }()

    /// Location of the helper executable (next to the main executable inside the bundle).
    public static var helperURL: URL {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("procopticon-helper")
    }

    // MARK: Executing requests

    /// Executes without ever prompting. Uses the most privileged channel available.
    public func perform(_ request: PrivilegedRequest) -> PrivilegedResponse {
        if geteuid() == 0 || Self.isLocalStream(request) {
            return local.handle(request)
        }
        lock.lock()
        let c = client
        lock.unlock()
        if let c {
            do {
                return try c.send(request)
            } catch {
                disconnect()
                return local.handle(request)
            }
        }
        return local.handle(request)
    }

    /// A read or stop of a stream this process started itself (a negative id; the helper's are
    /// positive). It must go back to this process even after the helper has started, or it would
    /// read, or stop, whichever of the helper's streams has the same number.
    static func isLocalStream(_ request: PrivilegedRequest) -> Bool {
        switch request {
        case .readStream(let id), .stopStream(let id): return id < 0
        default: return false
        }
    }

    /// Executes, and if the result is a permission failure (or `requiresRoot` is set) and we are not
    /// elevated, asks the user for administrator rights once and retries via the helper.
    public func performElevated(_ request: PrivilegedRequest, requiresRoot: Bool = false, prompt: Bool = true) async -> PrivilegedResponse {
        if mode != .standard {
            return await Task.detached { self.perform(request) }.value
        }
        if !requiresRoot {
            let response = await Task.detached { self.local.handle(request) }.value
            guard let error = response.error, error.isPermissionDenied, prompt else {
                return response
            }
        } else if !prompt {
            return .failure(PrivilegedError(code: EPERM, message: "Administrator privileges are required."))
        }
        do {
            try await startHelper()
        } catch let error as PrivilegedError {
            return .failure(error)
        } catch {
            return .failure(PrivilegedError(code: EPERM, message: error.localizedDescription))
        }
        return await Task.detached { self.perform(request) }.value
    }

    /// Executes in this process with its own privileges, even when the helper is running: for what
    /// must happen as the user (their app extension settings, say), not as root.
    public func performLocally(_ request: PrivilegedRequest) -> PrivilegedResponse {
        local.handle(request)
    }

    /// Stops the streaming tools running in this process (the helper stops its own on shutdown).
    public func stopLocalStreams() {
        local.stopAllStreams()
    }

    /// Whether acting on a process owned by `uid` needs root.
    public func needsRoot(forOwner uid: uid_t) -> Bool {
        uid != getuid() && geteuid() != 0
    }

    // MARK: Helper lifecycle

    /// Prompts for administrator credentials and starts the root helper.
    @MainActor
    public func startHelper() async throws {
        if mode != .standard { return }
        if launching {
            // Another caller is already authenticating; wait for it.
            for _ in 0..<600 where launching {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if mode != .standard { return }
            throw PrivilegedError.cancelled
        }
        launching = true
        defer { launching = false }

        let helper = Self.helperURL.path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw PrivilegedError(code: ENOENT, message: "The privileged helper is missing at \(helper).")
        }
        // The helper picks the path from the pid, in a directory only root can write to.
        let socket = HelperSocket.path(clientPid: getpid())
        // Root doesn't run the helper in the bundle, which other software running as the user could
        // have replaced: it copies it, checks the copy's signature against this app's, and runs that.
        let script = TrustedHelper.startScript(helper: helper, clientPid: getpid(), clientUid: getuid(),
                                               requirement: TrustedHelper.ownRequirement())
        // Passwordless sudo (NOPASSWD) avoids the dialog entirely; otherwise use the system prompt.
        let viaSudo = await Task.detached { Self.runWithPasswordlessSudo(script) }.value
        if let viaSudo {
            guard viaSudo.status == 0 else {
                let reason = viaSudo.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PrivilegedError(code: EPERM, message: reason.isEmpty ? "The privileged helper could not be started." : reason)
            }
        } else {
            try Self.runWithAdministratorPrivileges(script, prompt: "Procopticon needs administrator access to inspect and control processes owned by other users.")
        }

        let newClient = HelperClient(socketPath: socket)
        let connected = await Task.detached { () -> Bool in
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: socket), newClient.ping() {
                    return true
                }
                usleep(100_000)
            }
            return false
        }.value
        guard connected else {
            throw PrivilegedError(code: ETIMEDOUT, message: "The privileged helper did not start.")
        }
        setClient(newClient)
        EventLog.shared.add(.elevation, "Privileged helper started")
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func setClient(_ c: HelperClient?) {
        lock.lock()
        client = c
        lock.unlock()
    }

    public func stopHelper() {
        lock.lock()
        let c = client
        client = nil
        lock.unlock()
        if let c {
            // The helper removes its socket as it exits.
            _ = try? c.send(.shutdown)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private func disconnect() {
        lock.lock()
        let had = client != nil
        client = nil
        lock.unlock()
        if had {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }

    /// Runs shell commands as root through `sudo -n` when sudo needs no password; nil otherwise.
    static func runWithPasswordlessSudo(_ script: String) -> ToolOutput? {
        guard ToolRunner.run("/usr/bin/sudo", ["-n", "/usr/bin/true"], timeout: 5).status == 0 else {
            return nil
        }
        return ToolRunner.run("/usr/bin/sudo", ["-n", "/bin/sh", "-c", script], timeout: 60)
    }

    /// Starts `path` as root through `sudo -n` when sudo needs no password. Returns false otherwise.
    static func startWithPasswordlessSudo(_ path: String, _ args: [String]) -> Bool {
        guard ToolRunner.run("/usr/bin/sudo", ["-n", "/usr/bin/true"], timeout: 5).status == 0 else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", path] + args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }

    /// Runs a shell command as root through the standard macOS authorization dialog.
    @MainActor
    public static func runWithAdministratorPrivileges(_ command: String, prompt: String) throws {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw PrivilegedError(code: EINVAL, message: "Could not build the authorization request.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if number == -128 {
                throw PrivilegedError.cancelled
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Authorization failed."
            throw PrivilegedError(code: EPERM, message: message)
        }
    }

    /// Relaunches the current executable as root (no further prompts in that instance).
    @MainActor
    public static func relaunchAsRoot() throws {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).path
        if startWithPasswordlessSudo(exe, ["--relaunched-as-root"]) {
            return
        }
        let command = "SUDO_UID=\(getuid()) \(exe.shellQuoted) --relaunched-as-root >/dev/null 2>&1 &"
        try runWithAdministratorPrivileges(command, prompt: "Procopticon will restart with root privileges.")
    }
}
