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

    static func signal(_ items: [ProcessItem], _ sig: Int32, verb: String, explanation: String, confirm: Bool = true) {
        let targets = items.filter { !$0.isRemoved }
        guard !targets.isEmpty else { return }
        if confirm {
            let ok = Alerts.confirm("Do you want to \(verb.lowercased()) \(describe(targets))?",
                                    message: explanation + criticalWarning(targets), button: verb)
            guard ok else { return }
        }
        Task {
            var failures: [String] = []
            for p in targets {
                let response = await Elevation.shared.performElevated(.signal(pid: p.pid, signal: sig))
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
        var all: [ProcessItem] = []
        var seen = Set<ProcessKey>()
        for p in items {
            for q in [p] + p.descendants where !seen.contains(q.key) {
                seen.insert(q.key)
                all.append(q)
            }
        }
        // Children first so parents don't respawn them.
        all.reverse()
        signal(all, SIGTERM, verb: "Terminate Tree",
               explanation: "\(describe(items)) and all \(all.count - items.count) descendant processes will be terminated.")
    }

    static func suspend(_ items: [ProcessItem]) {
        signal(items, SIGSTOP, verb: "Suspend", explanation: "The process will be stopped (SIGSTOP) until resumed.")
    }

    static func resume(_ items: [ProcessItem]) {
        signal(items, SIGCONT, verb: "Resume", explanation: "", confirm: false)
    }

    static func suspendTree(_ items: [ProcessItem]) {
        let all = items.flatMap { [$0] + $0.descendants }
        signal(all, SIGSTOP, verb: "Suspend Tree", explanation: "\(all.count) processes will be stopped (SIGSTOP).")
    }

    static func resumeTree(_ items: [ProcessItem]) {
        let all = items.flatMap { [$0] + $0.descendants }
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
                let r = await Elevation.shared.performElevated(.setPriority(pid: p.pid, nice: value))
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
                let r = await Elevation.shared.performElevated(.setBackground(pid: p.pid, enabled: enabled))
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
        signal(items, sig, verb: "Send Signal", explanation: "Signal \(sig) will be sent.")
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
                             message: "The process will be terminated and started again with the same command line.", button: "Restart") else { return }
        let args = Array((p.record.arguments ?? [path]).dropFirst())
        let isApp = isApplication(p)
        let appPath = BundleInfoCache.outermostApplicationPath(path)
        let pid = p.pid
        let owner = p.record.uid
        Task {
            let r = await Elevation.shared.performElevated(.signal(pid: pid, signal: SIGTERM))
            if let e = r.error {
                Alerts.error("Unable to restart", e.message)
                return
            }
            for _ in 0..<50 where kill(pid, 0) == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if isApp, let appPath {
                let config = NSWorkspace.OpenConfiguration()
                config.arguments = args
                config.createsNewApplicationInstance = false
                _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config)
            } else if owner == 0, Elevation.interactiveUid != 0 {
                let r = await Elevation.shared.performElevated(.launch(path: path, arguments: args), requiresRoot: true)
                if let e = r.error { Alerts.error("Unable to restart", e.message) }
            } else {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = args
                do { try task.run() } catch { Alerts.error("Unable to restart", error.localizedDescription) }
            }
            ProcessStore.shared.refreshNow()
        }
    }

    static func sample(_ p: ProcessItem) {
        let pid = p.pid
        let needsRoot = Elevation.shared.needsRoot(forOwner: p.record.uid)
        Reports.show(title: "Sample of \(p.name) (\(pid))") {
            let file = NSTemporaryDirectory() + "sample-\(pid)-\(UUID().uuidString).txt"
            let out = await Reports.runTool("/usr/bin/sample", ["\(pid)", "3", "1", "-mayDie", "-file", file], requiresRoot: needsRoot)
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: file)
                return text
            }
            return out
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
            let file = NSTemporaryDirectory() + "spindump-\(pid)-\(UUID().uuidString).txt"
            let out = await Reports.runTool("/usr/sbin/spindump", ["\(pid)", "2", "10", "-file", file, "-noProcessingWhileSampling"], requiresRoot: true)
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                return text
            }
            return out
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
