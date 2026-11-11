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
    /// The window is reused while it's open, so the command that opens it sets the checkbox each
    /// time: "Run Program…" on a window opened by "Run Program as Root…" must not run as root.
    static func open(asRoot: Bool) {
        RunOptions.shared.asRoot = asRoot
        WindowManager.shared.show(id: "run", title: "Run Program", size: NSSize(width: 560, height: 220)) {
            RunView()
        }
    }
}

@MainActor
final class RunOptions: ObservableObject {
    static let shared = RunOptions()
    @Published var asRoot = false
}

struct RunView: View {
    @ObservedObject private var options = RunOptions.shared
    @State private var command = ""
    private var asRoot: Bool { options.asRoot }
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
            Toggle("Run as root", isOn: $options.asRoot).toggleStyle(.checkbox)
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
            // A root instance ("sudo mode") starts what isn't meant to run as root as the user.
            let asUser = !asRoot && geteuid() == 0 && Elevation.interactiveUid != 0
            if path.hasSuffix(".app"), asUser {
                do {
                    try ProcessActions.launch("/usr/bin/open", ["-a", path] + (args.isEmpty ? [] : ["--args"] + args),
                                              asUser: Elevation.interactiveUid)
                } catch {
                    Alerts.error("Unable to run \(path)", error.localizedDescription)
                    return
                }
            } else if path.hasSuffix(".app"), !asRoot {
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
                    do {
                        try ProcessActions.launch(exe, args, asUser: asUser ? Elevation.interactiveUid : getuid())
                    } catch {
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
