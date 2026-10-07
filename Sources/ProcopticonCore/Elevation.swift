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

    private var socketPath: String {
        let dir = NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("procopticon-\(getpid()).sock")
    }

    // MARK: Executing requests

    /// Executes without ever prompting. Uses the most privileged channel available.
    public func perform(_ request: PrivilegedRequest) -> PrivilegedResponse {
        if geteuid() == 0 {
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
        let socket = socketPath
        unlink(socket)
        let helperArgs = ["--serve", "--socket", socket, "--client-pid", "\(getpid())", "--client-uid", "\(getuid())"]
        // Passwordless sudo (NOPASSWD) avoids the dialog entirely; otherwise use the system prompt.
        let viaSudo = await Task.detached { Self.startWithPasswordlessSudo(helper, helperArgs) }.value
        if !viaSudo {
            let command = ([helper] + helperArgs).shellJoined + " >/dev/null 2>&1 &"
            try Self.runWithAdministratorPrivileges(command, prompt: "Procopticon needs administrator access to inspect and control processes owned by other users.")
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
            _ = try? c.send(.shutdown)
            unlink(c.socketPath)
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
