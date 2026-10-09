import AppKit
import Darwin
import ProcopticonCore
import SwiftUI

// MARK: - Find files or libraries

@MainActor
enum FindWindow {
    static func open() {
        WindowManager.shared.show(id: "find", title: "Find Files or Libraries", size: NSSize(width: 860, height: 520), autosave: "FindWindow") {
            FindView()
        }
    }
}

struct FindView: View {
    @AppStorage("findQuery") private var query = ""
    @State private var includeLibraries = true
    @State private var results: [OpenFileMatch] = []
    @State private var searching = false
    @State private var revision = 0
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(AppSettings.shared.searchUsesRegex ? "Regular expression for file, socket or library paths" : "File, directory, socket path or library name (or /regex/)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                RegexToggle()
                    .toggleStyle(.button)
                Toggle("Include libraries & mapped files", isOn: $includeLibraries).toggleStyle(.checkbox)
                Button("Find", action: search)
                    .help("Search every process's open files, sockets and loaded libraries")
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            .padding(10)
            HStack {
                if searching { ProgressView().controlSize(.small) }
                Text(message).foregroundStyle(.secondary)
                Spacer()
                if Elevation.shared.mode == .standard {
                    Text("Only your own processes are searched until you authorize.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()
            OutlineTable(
                roots: results,
                children: nil,
                revision: revision,
                columns: Self.columns,
                autosaveName: "FindResults",
                key: { AnyHashable($0.id) },
                menu: { rows in
                    let m = NSMenu()
                    guard let r = rows.first else { return m }
                    m.add("Go to Process") { ProcessSelection.shared.reveal(pid: r.pid) }
                    if let p = ProcessStore.shared.item(pid: r.pid) {
                        m.add("Process Properties") { PropertiesWindow.open(p) }
                        m.add("Terminate Process") { ProcessActions.terminate([p]) }
                    }
                    if FileManager.default.fileExists(atPath: r.name) {
                        m.add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.name)]) }
                    }
                    return m
                },
                onDoubleClick: { ProcessSelection.shared.reveal(pid: $0.pid) })
        }
        .task { if !query.isEmpty, CommandLine.arguments.contains("--show-find") { search() } }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let regex = AppSettings.shared.searchUsesRegex
        if let error = SearchMatcher(q, regex: regex).error {
            message = error
            results = []
            revision &+= 1
            return
        }
        searching = true
        message = "Searching…"
        let libs = includeLibraries
        Task {
            let response = await Task.detached { Elevation.shared.perform(.searchOpenFiles(query: q, includeLibraries: libs, regex: regex)) }.value
            if case .openFiles(let h) = response {
                results = h
                message = "\(h.count) results in \(Set(h.map(\.pid)).count) processes"
            } else {
                results = []
                message = response.error?.message ?? "No results"
            }
            searching = false
            revision &+= 1
        }
    }

    static let columns: [TableColumnSpec<OpenFileMatch>] = {
        var name = TableColumnSpec<OpenFileMatch>.string("process", "Process", width: 180, help: "The process that has it open") { $0.processName }
        name.image = { m in ProcessStore.shared.item(pid: m.pid).map { ProcessIcons.icon(for: $0.record) } ?? ProcessIcons.executable }
        return [
            name,
            .number("pid", "PID", width: 60, help: "Process ID", value: { $0.pid }, text: { "\($0.pid)" }),
            .string("type", "Type", width: 110, help: "What's open: a file, directory, socket…, or an image or file mapped into memory") { $0.type },
            .number("fd", "FD", width: 50,
                    help: "File descriptor number; blank for images and mapped files",
                    value: { $0.fd ?? -1 }, text: { $0.fd.map { "\($0)" } ?? "" }),
            .string("name", "Name", width: 460, help: "Path, or a description of what's open") { $0.name },
        ]
    }()
}

// MARK: - Hidden processes

@MainActor
enum HiddenProcessesWindow {
    static func open() {
        WindowManager.shared.show(id: "hidden", title: "Hidden Process Scan", size: NSSize(width: 720, height: 460)) {
            HiddenProcessesView()
        }
    }
}

struct HiddenProcessesView: View {
    struct Finding: Hashable {
        var pid: Int32
        var name: String
        var detail: String
    }

    @State private var findings: [Finding] = []
    @State private var summary = "Compares the kernel process list against a brute-force scan of every possible PID to find processes that are hidden from enumeration (e.g. by rootkits)."
    @State private var scanning = false
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(summary).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button("Scan", action: scan).disabled(scanning).keyboardShortcut(.defaultAction)
                    .help("Probe every possible PID and compare with the kernel's process list, to find processes hidden from it")
            }
            .padding(10)
            Divider()
            OutlineTable(roots: findings, children: nil, revision: revision,
                         columns: [
                             .number("pid", "PID", width: 70, help: "Process ID found by the scan", value: { $0.pid }, text: { "\($0.pid)" }),
                             .string("name", "Name", width: 180, help: "Executable name, if it could be read") { $0.name },
                             .string("detail", "Finding", width: 400, help: "Why the process looks hidden") { $0.detail },
                         ],
                         autosaveName: "HiddenScan", key: { AnyHashable($0.pid) })
        }
    }

    private func scan() {
        scanning = true
        Task.detached {
            let result = HiddenProcessScanner.scan()
            await MainActor.run {
                findings = result.findings.map { Finding(pid: $0.pid, name: $0.name, detail: $0.detail) }
                summary = "Scanned \(result.probed) PIDs. Kernel list: \(result.listed) processes, brute force: \(result.found). " +
                    (findings.isEmpty ? "No hidden processes found." : "\(findings.count) discrepancies (processes that started or exited during the scan also appear here).")
                scanning = false
                revision &+= 1
            }
        }
    }
}

enum HiddenProcessScanner {
    struct Result {
        var probed: Int
        var listed: Int
        var found: Int
        var findings: [(pid: Int32, name: String, detail: String)]
    }

    static func scan() -> Result {
        let listedPids = Set(ProcessSampler.lightweightList().map(\.0))
        var libprocPids = [Int32](repeating: 0, count: 8192)
        let n = proc_listallpids(&libprocPids, Int32(libprocPids.count * MemoryLayout<Int32>.size))
        let libprocSet = Set(libprocPids.prefix(Int(max(0, n))))
        var found = Set<Int32>()
        let maxPid: Int32 = 99_999
        for pid in 0...maxPid {
            if kill(pid, 0) == 0 || errno == EPERM {
                found.insert(pid)
            }
        }
        found.insert(0)
        var findings: [(Int32, String, String)] = []
        for pid in found.subtracting(listedPids).sorted() {
            // Re-check to filter processes that just started.
            let stillExists = kill(pid, 0) == 0 || errno == EPERM
            guard stillExists, !Set(ProcessSampler.lightweightList().map(\.0)).contains(pid) else { continue }
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let name = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? (String(cString: buf) as NSString).lastPathComponent : "?"
            findings.append((pid, name, "Responds to signals but is missing from the kernel process list"))
        }
        for pid in listedPids.subtracting(libprocSet).sorted() where pid != 0 {
            findings.append((pid, "", "Listed by sysctl but missing from proc_listallpids"))
        }
        return Result(probed: Int(maxPid) + 1, listed: listedPids.count, found: found.count, findings: findings)
    }
}

// MARK: - Users

@MainActor
enum UsersWindow {
    static func open() {
        WindowManager.shared.show(id: "users", title: "Logged-in Users", size: NSSize(width: 760, height: 420)) {
            UsersView()
        }
    }
}

struct UsersView: View {
    @ObservedObject private var store = ProcessStore.shared

    struct UserRow: Hashable {
        var uid: uid_t
        var name: String
        var fullName: String
        var processes: Int
        var cpu: Double
        var memory: UInt64
        var sessions: String
    }

    var body: some View {
        OutlineTable(roots: rows, children: nil, revision: store.revision,
                     columns: [
                         .string("name", "User", width: 120, help: "Account name") { $0.name },
                         .number("uid", "UID", width: 60, help: "User ID", value: { $0.uid }, text: { "\($0.uid)" }),
                         .string("full", "Full name", width: 160, help: "The account's full name") { $0.fullName },
                         .number("procs", "Processes", width: 80,
                                 help: "Number of processes running as the user",
                                 value: { $0.processes }, text: { "\($0.processes)" }),
                         Self.cpuColumn,
                         .number("mem", "Memory", width: 90,
                                 help: "Combined memory footprint of the user's processes",
                                 value: { $0.memory }, text: { Fmt.bytes($0.memory) }),
                         .string("sessions", "Sessions", width: 260, help: "Login sessions: terminal, remote host and login time") { $0.sessions },
                     ],
                     autosaveName: "UsersTable", key: { AnyHashable($0.uid) },
                     menu: { rows in
                         let m = NSMenu()
                         if let r = rows.first {
                             m.add("Show Processes of \(r.name)") {
                                 ProcessStore.shared.filter.text = r.name
                                 NotificationCenter.default.post(name: .showTab, object: MainTab.processes)
                             }
                         }
                         return m
                     },
                     defaultSort: (column: "procs", ascending: false))
    }

    private static var cpuColumn: TableColumnSpec<UserRow> {
        var cpu = TableColumnSpec<UserRow>.number("cpu", "CPU", width: 60, help: "Combined CPU usage of the user's processes",
                                                  value: { $0.cpu }, text: { Fmt.percent($0.cpu) })
        cpu.attributedText = { ProcessColumns.cpuPercent($0.cpu) }
        return cpu
    }

    private var rows: [UserRow] {
        let sessions = LoginSession.current()
        var byUid: [uid_t: UserRow] = [:]
        for p in store.items.values where !p.isRemoved {
            let uid = p.record.uid
            var row = byUid[uid] ?? UserRow(uid: uid, name: UserNames.name(uid), fullName: UserNames.fullName(uid), processes: 0, cpu: 0, memory: 0, sessions: "")
            row.processes += 1
            row.cpu += p.cpu
            row.memory += p.stats?.physFootprint ?? 0
            byUid[uid] = row
        }
        for (uid, row) in byUid {
            let s = sessions.filter { $0.user == row.name }
            byUid[uid]?.sessions = s.map { "\($0.line)\($0.host.isEmpty ? "" : " from \($0.host)") since \($0.loginTime.formatted(date: .abbreviated, time: .shortened))" }
                .joined(separator: "; ")
        }
        return Array(byUid.values)
    }
}

// MARK: - Run

@MainActor
enum RunWindow {
    static func open(asRoot: Bool) {
        WindowManager.shared.show(id: "run", title: "Run Program", size: NSSize(width: 560, height: 220)) {
            RunView(asRoot: asRoot)
        }
    }
}

struct RunView: View {
    @State var asRoot: Bool
    @State private var command = ""
    @AppStorage("runHistory") private var historyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type the path of a program or application, followed by arguments.").foregroundStyle(.secondary)
            HStack {
                TextField("/usr/bin/top -l 1   or   /Applications/Safari.app", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Menu {
                    ForEach(history, id: \.self) { h in Button(h) { command = h } }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30)
                    .disabled(history.isEmpty)
                    .help("Recent commands")
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        command = url.path.shellQuoted
                    }
                }
                .help("Pick a program or application in a file browser")
            }
            Toggle("Run as root", isOn: $asRoot).toggleStyle(.checkbox)
            if asRoot, Elevation.shared.mode == .standard {
                Text("You will be asked for administrator credentials.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { WindowManager.shared.close(id: "run") }.keyboardShortcut(.cancelAction)
                    .help("Close without running anything (Esc)")
                Button("Run", action: run).keyboardShortcut(.defaultAction)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Run the command (Return)")
            }
        }
        .padding(16)
    }

    private var history: [String] {
        historyText.split(separator: "\n").map(String.init)
    }

    private func run() {
        let words = ShellWords.split(command)
        guard let first = words.first else { return }
        let path = (first as NSString).expandingTildeInPath
        let args = Array(words.dropFirst())
        var h = history.filter { $0 != command }
        h.insert(command, at: 0)
        historyText = h.prefix(15).joined(separator: "\n")
        Task {
            if path.hasSuffix(".app"), !asRoot {
                let config = NSWorkspace.OpenConfiguration()
                config.arguments = args
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
                } catch {
                    Alerts.error("Unable to run \(path)", error.localizedDescription)
                    return
                }
            } else {
                var exe = path
                if path.hasSuffix(".app"), let e = Bundle(path: path)?.executablePath { exe = e }
                if !exe.contains("/") {
                    exe = ShellWords.which(exe) ?? exe
                }
                if asRoot {
                    let r = await Elevation.shared.performElevated(.launch(path: exe, arguments: args), requiresRoot: true)
                    if let e = r.error {
                        if e != .cancelled { Alerts.error("Unable to run \(exe)", e.message) }
                        return
                    }
                } else {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: exe)
                    p.arguments = args
                    do { try p.run() } catch {
                        Alerts.error("Unable to run \(exe)", error.localizedDescription)
                        return
                    }
                }
            }
            WindowManager.shared.close(id: "run")
            ProcessStore.shared.refreshNow()
        }
    }
}

enum ShellWords {
    /// Splits a command line honoring single/double quotes and backslash escapes.
    static func split(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for c in s {
            if escape {
                current.append(c)
                escape = false
                inWord = true
                continue
            }
            if c == "\\", quote != "'" {
                escape = true
                continue
            }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                inWord = true
                continue
            }
            if c == " " || c == "\t" {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
                continue
            }
            current.append(c)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }

    static func which(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        for dir in paths.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
