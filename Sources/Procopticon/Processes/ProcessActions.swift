import AppKit
import ProcopticonCore

/// User-initiated operations on processes. Elevates automatically when an operation is denied.
@MainActor
enum ProcessActions {
    static let criticalNames: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow", "logd", "opendirectoryd", "securityd", "configd", "UserEventAgent", "mds", "notifyd", "coreservicesd"]

    static func describe(_ items: [ProcessItem]) -> String {
        if items.count == 1, let p = items.first {
            return "\(p.name) (\(p.pid))"
        }
        return "\(items.count) processes"
    }

    private static func criticalWarning(_ items: [ProcessItem]) -> String {
        let critical = items.filter { criticalNames.contains($0.name) || $0.pid <= 1 }
        guard !critical.isEmpty else { return "" }
        return "\n\nWarning: \(critical.map(\.name).joined(separator: ", ")) is critical to macOS. Ending it may log you out or restart the system."
    }

    /// Procopticon itself or the root helper serving it. A tree action that reaches them (the tree
    /// of launchd, or of the terminal Procopticon was started from) would end or freeze the app
    /// partway through its own list.
    static func isOwnProcess(_ p: ProcessItem) -> Bool {
        if p.pid == getpid() { return true }
        guard p.name == "procopticon-helper", let arguments = p.record.arguments else { return false }
        return arguments.firstIndex(of: "--client-pid").map { $0 + 1 < arguments.count && arguments[$0 + 1] == "\(getpid())" } ?? false
    }

    /// `items` with their descendants, each process once, parents before their children.
    private static func withDescendants(_ items: [ProcessItem]) -> [ProcessItem] {
        var all: [ProcessItem] = []
        var seen = Set<ProcessKey>()
        for p in items {
            for q in [p] + ProcessStore.shared.descendants(of: p) where seen.insert(q.key).inserted {
                all.append(q)
            }
        }
        return all
    }

    /// What a tree action on `items` acts on, without Procopticon itself, and how to say so.
    private static func tree(_ items: [ProcessItem]) -> (targets: [ProcessItem], descendants: Int, note: String) {
        let all = withDescendants(items)
        let targets = all.filter { !isOwnProcess($0) }
        let roots = Set(items.map(\.key))
        let note = targets.count < all.count ? " Procopticon itself is left out." : ""
        return (targets, targets.filter { !roots.contains($0.key) }.count, note)
    }

    /// `kind` is what "Don't ask again" covers (see `Alerts.confirm`); the verb unless given.
    static func signal(_ items: [ProcessItem], _ sig: Int32, verb: String, explanation: String, confirm: Bool = true,
                       kind: String? = nil) {
        let targets = items.filter { !$0.isRemoved }
        guard !targets.isEmpty else { return }
        if confirm {
            let warning = criticalWarning(targets)
            let ok = Alerts.confirm("Do you want to \(verb.lowercased()) \(describe(targets))?",
                                    message: explanation + warning, button: verb, kind: kind ?? verb, critical: !warning.isEmpty)
            guard ok else { return }
        }
        Task {
            var failures: [String] = []
            for p in targets {
                let response = await Elevation.shared.performElevated(.signal(pid: p.pid, signal: sig, startMicros: p.record.startMicros))
                if let e = response.error, e != PrivilegedError.cancelled {
                    failures.append("\(p.name) (\(p.pid)): \(e.message)")
                } else if response.error == nil {
                    EventLog.shared.add(.action, pid: p.pid, "Sent signal \(sig) (\(verb)) to \(p.name) (\(p.pid))")
                }
            }
            if !failures.isEmpty {
                Alerts.error("Unable to \(verb.lowercased()) \(failures.count == 1 ? "the process" : "\(failures.count) processes")", failures.joined(separator: "\n"))
            }
            ProcessStore.shared.refreshNow()
        }
    }

    static func terminate(_ items: [ProcessItem]) {
        signal(items, SIGTERM, verb: "Terminate", explanation: "The process will be asked to quit (SIGTERM). Unsaved data may be lost.")
    }

    static func forceKill(_ items: [ProcessItem]) {
        signal(items, SIGKILL, verb: "Force Kill", explanation: "The process will be killed immediately (SIGKILL) and cannot clean up. Unsaved data will be lost.")
    }

    static func terminateTree(_ items: [ProcessItem]) {
        let tree = tree(items)
        // Children first so parents don't respawn them.
        signal(tree.targets.reversed(), SIGTERM, verb: "Terminate Tree",
               explanation: "\(describe(items)) and all \(tree.descendants) descendant processes will be terminated.\(tree.note)")
    }

    static func suspend(_ items: [ProcessItem]) {
        // Stopped, Procopticon couldn't be asked to resume itself.
        let targets = items.filter { !isOwnProcess($0) }
        guard !targets.isEmpty else {
            Alerts.error("Procopticon can't suspend itself", "It couldn't resume itself afterwards.")
            return
        }
        signal(targets, SIGSTOP, verb: "Suspend", explanation: "The process will be stopped (SIGSTOP) until resumed.")
    }

    static func resume(_ items: [ProcessItem]) {
        signal(items, SIGCONT, verb: "Resume", explanation: "", confirm: false)
    }

    static func suspendTree(_ items: [ProcessItem]) {
        let tree = tree(items)
        signal(tree.targets, SIGSTOP, verb: "Suspend Tree",
               explanation: "\(tree.targets.count) processes will be stopped (SIGSTOP).\(tree.note)")
    }

    static func resumeTree(_ items: [ProcessItem]) {
        let all = withDescendants(items)
        signal(all, SIGCONT, verb: "Resume", explanation: "", confirm: false)
    }

    static let signals: [(Int32, String)] = [
        (SIGHUP, "SIGHUP — Hang up / reload"), (SIGINT, "SIGINT — Interrupt"), (SIGQUIT, "SIGQUIT — Quit"),
        (SIGTERM, "SIGTERM — Terminate"), (SIGKILL, "SIGKILL — Kill"), (SIGSTOP, "SIGSTOP — Stop"),
        (SIGCONT, "SIGCONT — Continue"), (SIGTSTP, "SIGTSTP — Terminal stop"), (SIGUSR1, "SIGUSR1 — User 1"),
        (SIGUSR2, "SIGUSR2 — User 2"), (SIGINFO, "SIGINFO — Status request"), (SIGABRT, "SIGABRT — Abort"),
        (SIGALRM, "SIGALRM — Alarm"), (SIGWINCH, "SIGWINCH — Window size change"), (SIGPIPE, "SIGPIPE — Broken pipe"),
    ]

    static let priorities: [(Int32, String)] = [
        (-20, "Highest (-20)"), (-10, "High (-10)"), (-5, "Above normal (-5)"), (0, "Normal (0)"),
        (5, "Below normal (5)"), (10, "Low (10)"), (20, "Lowest (20)"),
    ]

    static func setNice(_ items: [ProcessItem], _ value: Int32) {
        Task {
            var failures: [String] = []
            for p in items {
                let r = await Elevation.shared.performElevated(.setPriority(pid: p.pid, nice: value, startMicros: p.record.startMicros))
                if let e = r.error, e != PrivilegedError.cancelled {
                    failures.append("\(p.name): \(e.message)")
                }
            }
            if !failures.isEmpty {
                Alerts.error("Unable to change priority", failures.joined(separator: "\n"))
            }
            ProcessStore.shared.refreshNow()
        }
    }

    static func setBackground(_ items: [ProcessItem], _ enabled: Bool) {
        Task {
            var failures: [String] = []
            for p in items {
                let r = await Elevation.shared.performElevated(.setBackground(pid: p.pid, enabled: enabled, startMicros: p.record.startMicros))
                if let e = r.error, e != PrivilegedError.cancelled {
                    failures.append("\(p.name): \(e.message)")
                }
            }
            if !failures.isEmpty {
                Alerts.error("Unable to change the scheduling policy", failures.joined(separator: "\n"))
            }
        }
    }

    static func customSignal(_ items: [ProcessItem]) {
        guard let text = Alerts.prompt("Send Signal", message: "Signal number or name (e.g. 15, TERM, SIGUSR1):", defaultValue: "SIGTERM", button: "Send") else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        var number = Int32(trimmed)
        if number == nil {
            let name = trimmed.hasPrefix("SIG") ? trimmed : "SIG" + trimmed
            number = signals.first { $0.1.hasPrefix(name + " ") }?.0
        }
        guard let sig = number, sig > 0, sig < NSIG else {
            Alerts.error("Unknown signal", "\"\(text)\" is not a valid signal.")
            return
        }
        signal(items, sig, verb: "Send Signal", explanation: "Signal \(sig) will be sent.", kind: signalKind(sig))
    }

    /// Each signal is its own kind of action: not being asked again about SIGUSR1 mustn't also
    /// mean not being asked about SIGKILL.
    static func signalKind(_ sig: Int32) -> String {
        let name = signals.first { $0.0 == sig }?.1.components(separatedBy: " ").first
        return "Send \(name ?? "Signal \(sig)")"
    }

    static func revealInFinder(_ p: ProcessItem) {
        guard let path = p.record.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func revealBundle(_ p: ProcessItem) {
        guard let path = p.record.path else { return }
        let target = BundleInfoCache.outermostApplicationPath(path) ?? path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    static func searchOnline(_ p: ProcessItem) {
        let query = p.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? p.name
        let template = AppSettings.shared.searchEngineURL
        if let url = URL(string: template.replacingOccurrences(of: "%s", with: query)) {
            NSWorkspace.shared.open(url)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func bringToFront(_ p: ProcessItem) {
        NSRunningApplication(processIdentifier: p.pid)?.activate()
    }

    static func isApplication(_ p: ProcessItem) -> Bool {
        NSRunningApplication(processIdentifier: p.pid)?.activationPolicy == .regular
    }

    /// Quit gracefully through the application (Apple Event) rather than a signal.
    static func quitApplication(_ p: ProcessItem) {
        NSRunningApplication(processIdentifier: p.pid)?.terminate()
    }

    /// Terminates and relaunches with the same executable and arguments.
    static func restart(_ p: ProcessItem) {
        guard let path = p.record.path else { return }
        guard Alerts.confirm("Do you want to restart \(describe([p]))?",
                             message: "The process will be terminated and started again with the same command line." + criticalWarning([p]),
                             button: "Restart", kind: "Restart", critical: !criticalWarning([p]).isEmpty) else { return }
        // A process that replaced its arguments with a title before it was first seen can't be
        // started the way it was: what it was started with is gone.
        guard !p.record.argumentsOverwritten else {
            Alerts.error("Unable to restart \(p.name)",
                         "It replaced its arguments with its title, so the command line it was started with isn't known. It was left running.")
            return
        }
        let known = p.record.commandLineArguments
        let isApp = isApplication(p)
        let appPath = BundleInfoCache.outermostApplicationPath(path)
        let key = p.key
        let owner = p.record.uid
        let name = p.name
        Task {
            // The arguments of another user's process can't be read without root. Starting it
            // again without them would run something else under the same name, so they are read
            // through the helper first, and without them the process is left running.
            var all = known
            if all == nil {
                let reply = await Elevation.shared.performElevated(.arguments(pid: key.pid), requiresRoot: true)
                if case .arguments(let read) = reply, key.isRunning {
                    all = read.arguments
                } else {
                    if reply.error != .cancelled {
                        Alerts.error("Unable to restart \(name)",
                                     "Its arguments couldn't be read, so it couldn't be started again the same way. It was left running."
                                        + (reply.error.map { "\n\n\($0.message)" } ?? ""))
                    }
                    return
                }
            }
            let args = Array((all ?? []).dropFirst())
            let existing = Set(runningCopies(of: path))
            let r = await Elevation.shared.performElevated(.signal(pid: key.pid, signal: SIGTERM, startMicros: key.startMicros))
            if let e = r.error {
                if e != .cancelled { Alerts.error("Unable to restart", e.message) }
                return
            }
            for _ in 0..<50 where key.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            defer { ProcessStore.shared.refreshNow() }
            // Starting it now would leave two copies running.
            guard !key.isRunning else {
                Alerts.error("Unable to restart \(name)",
                             "It was asked to quit (SIGTERM) and is still running after 5 seconds, so it wasn't started again. Force Kill ends it at once.")
                return
            }
            // launchd restarts the jobs it keeps alive by itself; give it a moment to.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Set(runningCopies(of: path)).subtracting(existing).isEmpty {
                EventLog.shared.add(.action, pid: key.pid, "Restarted \(name) (\(key.pid)): it was started again on its own (by launchd, or whatever watches over it)")
                return
            }
            do {
                if isApp, let appPath {
                    if owner != geteuid() {
                        // Opened from here, the application would belong to the user Procopticon runs as.
                        try await launch("/usr/bin/open", ["-a", appPath] + (args.isEmpty ? [] : ["--args"] + args), asOwner: owner)
                    } else {
                        let config = NSWorkspace.OpenConfiguration()
                        config.arguments = args
                        config.createsNewApplicationInstance = false
                        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config)
                    }
                } else {
                    try await launch(path, args, asOwner: owner)
                }
            } catch {
                Alerts.error("Unable to restart \(name)", error.localizedDescription)
            }
        }
    }

    /// The running processes whose executable is `path`.
    private static func runningCopies(of path: String) -> [ProcessKey] {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return ProcessSampler.lightweightList().compactMap { pid, _ in
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == path else { return nil }
            return ProcessKey.current(pid: pid)
        }
    }

    /// Starts `path` as the user who owned the process being restarted. Without root that is only
    /// possible for the user's own processes; the rest goes through the helper, which starts
    /// root's directly and anyone else's through `sudo -u`.
    private static func launch(_ path: String, _ arguments: [String], asOwner uid: uid_t) async throws {
        if geteuid() == 0 || uid == geteuid() {
            try launch(path, arguments, asUser: uid)
            return
        }
        let request: PrivilegedRequest = uid == 0
            ? .launch(path: path, arguments: arguments)
            : .launch(path: "/usr/bin/sudo", arguments: ["-n", "-H", "-u", "#\(uid)", "--", path] + arguments)
        let reply = await Elevation.shared.performElevated(request, requiresRoot: true)
        if let error = reply.error, error != .cancelled { throw error }
    }

    /// Starts `path` detached, as the user `uid`. Procopticon running as root ("sudo mode") would
    /// otherwise start everything as root, including what the user meant to run as themselves and
    /// the processes of theirs it restarts; there it goes through `sudo -u`. Without root it can
    /// only start things as the user it runs as.
    static func launch(_ path: String, _ arguments: [String], asUser uid: uid_t) throws {
        let task = Process()
        if geteuid() == 0, uid != 0 {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", "-H", "-u", "#\(uid)", "--", path] + arguments
        } else {
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = arguments
        }
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
    }

    static func sample(_ p: ProcessItem) {
        let pid = p.pid
        let needsRoot = Elevation.shared.needsRoot(forOwner: p.record.uid)
        Reports.show(title: "Sample of \(p.name) (\(pid))") {
            await Reports.runToolReport("/usr/bin/sample", ["\(pid)", "3", "1", "-mayDie", "-file", ToolReport.placeholder], requiresRoot: needsRoot)
        }
    }

    static func vmmap(_ p: ProcessItem, summary: Bool) {
        let pid = p.pid
        let needsRoot = Elevation.shared.needsRoot(forOwner: p.record.uid)
        Reports.show(title: "Virtual memory of \(p.name) (\(pid))") {
            await Reports.runTool("/usr/bin/vmmap", summary ? ["-summary", "\(pid)"] : ["-interleaved", "-wide", "\(pid)"], requiresRoot: needsRoot)
        }
    }

    static func heap(_ p: ProcessItem) {
        let pid = p.pid
        let needsRoot = Elevation.shared.needsRoot(forOwner: p.record.uid)
        Reports.show(title: "Heap of \(p.name) (\(pid))") {
            await Reports.runTool("/usr/bin/heap", ["\(pid)"], requiresRoot: needsRoot)
        }
    }

    static func leaks(_ p: ProcessItem) {
        let pid = p.pid
        let needsRoot = Elevation.shared.needsRoot(forOwner: p.record.uid)
        Reports.show(title: "Leaks in \(p.name) (\(pid))") {
            await Reports.runTool("/usr/bin/leaks", ["\(pid)"], requiresRoot: needsRoot)
        }
    }

    static func footprint(_ p: ProcessItem) {
        let pid = p.pid
        let needsRoot = Elevation.shared.needsRoot(forOwner: p.record.uid)
        Reports.show(title: "Memory footprint of \(p.name) (\(pid))") {
            await Reports.runTool("/usr/bin/footprint", ["-p", "\(pid)"], requiresRoot: needsRoot)
        }
    }

    static func spindump(_ p: ProcessItem) {
        let pid = p.pid
        Reports.show(title: "Spindump of \(p.name) (\(pid))") {
            await Reports.runToolReport("/usr/sbin/spindump", ["\(pid)", "2", "10", "-file", ToolReport.placeholder, "-noProcessingWhileSampling"], requiresRoot: true)
        }
    }

    static func openFiles(_ p: ProcessItem) {
        let pid = p.pid
        let needsRoot = Elevation.shared.needsRoot(forOwner: p.record.uid)
        Reports.show(title: "lsof of \(p.name) (\(pid))") {
            await Reports.runTool("/usr/sbin/lsof", ["-n", "-P", "-p", "\(pid)"], requiresRoot: needsRoot)
        }
    }

    static func createCoreDump(_ p: ProcessItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name)-\(p.pid).core"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pid = p.pid
        let needsRoot = Elevation.shared.needsRoot(forOwner: p.record.uid)
        Reports.show(title: "Core dump of \(p.name) (\(pid))") {
            var out = await Reports.runTool("/usr/bin/gcore", ["-o", url.path, "\(pid)"], requiresRoot: needsRoot)
            if FileManager.default.fileExists(atPath: url.path) {
                out += "\n\nCore dump written to \(url.path)"
            } else {
                out += "\n\nNo core file was produced. Processes with the hardened runtime (and Apple platform binaries while System Integrity Protection is enabled) cannot be dumped."
            }
            return out
        }
    }
}

extension PrivilegedError: Equatable {
    public static func == (a: PrivilegedError, b: PrivilegedError) -> Bool {
        a.code == b.code && a.message == b.message
    }
}
