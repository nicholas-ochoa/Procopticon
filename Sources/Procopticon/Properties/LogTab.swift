import AppKit
import ProcopticonCore
import SwiftUI

/// Follows a process's messages in the unified log (`log stream`), after those from the last few
/// minutes (`log show`).
@MainActor
final class ProcessLogModel: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var revision = 0
    @Published var level: UnifiedLog.Level = .default {
        didSet { if level != oldValue { restart() } }
    }
    @Published var paused = false {
        didSet { if !paused { flushPending() } }
    }
    @Published private(set) var pendingCount = 0
    @Published private(set) var error: String?
    @Published private(set) var needsAdministrator = false
    @Published private(set) var loadingHistory = false
    @Published private(set) var droppedBytes = 0

    static let capacity = 10_000
    private let pid: Int32
    private let startTime: Double
    private var stream: ToolStream?
    private var streamStarted = Date()
    private var pending: [LogEntry] = []
    private var nextId = 0
    private var historyTask: Task<Void, Never>?

    init(pid: Int32, startTime: Double) {
        self.pid = pid
        self.startTime = startTime
    }

    func start() {
        guard stream == nil else { return }
        error = nil
        needsAdministrator = false
        let stream = ToolStream(tool: "/usr/bin/log", arguments: UnifiedLog.streamArguments(pid: pid, level: level))
        self.stream = stream
        streamStarted = Date()
        Task { [weak self] in
            if let e = await stream.start(handler: { [weak self] in self?.handle($0) }) {
                self?.fail(e.message)
            }
        }
        loadHistory(seconds: 5 * 60)
    }

    func stop() {
        stream?.stop()
        stream = nil
        historyTask?.cancel()
        historyTask = nil
        loadingHistory = false
    }

    func restart() {
        stop()
        entries = []
        pending = []
        pendingCount = 0
        revision &+= 1
        start()
    }

    func clear() {
        entries = []
        pending = []
        pendingCount = 0
        droppedBytes = 0
        revision &+= 1
    }

    /// Adds the messages logged in the last `seconds` before the live ones.
    func loadHistory(seconds: Int) {
        historyTask?.cancel()
        loadingHistory = true
        let args = UnifiedLog.showArguments(pid: pid, level: level, lastSeconds: seconds)
        let cutoff = streamStarted
        historyTask = Task {
            let response = await Task.detached { Elevation.shared.perform(.runTool(tool: "/usr/bin/log", arguments: args)) }.value
            guard !Task.isCancelled else { return }
            loadingHistory = false
            guard case .tool(let out) = response else { return }
            var lines = out.stdout.split(separator: "\n")
            if lines.count > Self.capacity {
                lines = lines.suffix(Self.capacity)
            }
            let known = Set(entries.map { "\($0.date.timeIntervalSince1970)\($0.threadID)\($0.message)" })
            var earlier: [LogEntry] = []
            for line in lines {
                guard var e = UnifiedLog.parse(String(line), id: 0), e.date < cutoff else { continue }
                guard !known.contains("\(e.date.timeIntervalSince1970)\(e.threadID)\(e.message)") else { continue }
                nextId += 1
                e.id = -nextId
                earlier.append(e)
            }
            guard !earlier.isEmpty else { return }
            let live = entries.filter { $0.date >= cutoff }
            let older = entries.filter { $0.date < cutoff }
            entries = Array((earlier + older).sorted { $0.date < $1.date }.suffix(Self.capacity - min(live.count, Self.capacity)) + live)
            revision &+= 1
        }
    }

    /// Since the process started, capped at a day.
    func loadSinceStart() {
        let seconds = Int(min(86_400, max(60, Date().timeIntervalSince1970 - startTime + 5)))
        loadHistory(seconds: seconds)
    }

    private func handle(_ event: ToolStream.Event) {
        switch event {
        case .lines(let lines):
            var new: [LogEntry] = []
            for line in lines {
                nextId += 1
                if let e = UnifiedLog.parse(line, id: nextId) {
                    new.append(e)
                }
            }
            guard !new.isEmpty else { return }
            if paused {
                pending.append(contentsOf: new)
                if pending.count > Self.capacity {
                    pending.removeFirst(pending.count - Self.capacity)
                }
                pendingCount = pending.count
            } else {
                append(new)
            }
        case .dropped(let bytes):
            droppedBytes += bytes
        case .finished(let status, let errorOutput):
            stream = nil
            if status != 0 {
                fail(errorOutput.isEmpty ? "log exited with status \(status)." : errorOutput)
            }
        }
    }

    private func append(_ new: [LogEntry]) {
        entries.append(contentsOf: new)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        revision &+= 1
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        append(pending)
        pending = []
        pendingCount = 0
    }

    private func fail(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only administrators may read the log; anyone can once the root helper runs.
        needsAdministrator = text.localizedCaseInsensitiveContains("admin") && !Elevation.shared.isElevated
        error = text
    }
}

struct ProcessLogTab: View {
    let item: ProcessItem
    @StateObject private var model: ProcessLogModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var search = ""

    init(item: ProcessItem) {
        self.item = item
        _model = StateObject(wrappedValue: ProcessLogModel(pid: item.pid, startTime: item.record.startTime))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.needsAdministrator {
                AccessDeniedView(message: "Only administrators can read the unified log. Authorize to read it through the privileged helper.") {
                    model.restart()
                }
            } else if let error = model.error, model.entries.isEmpty {
                ContentUnavailableView("Log unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OutlineTable(
                    roots: rows,
                    children: nil,
                    revision: model.revision &+ search.hashValue &+ (settings.searchUsesRegex ? 1 : 0),
                    columns: Self.columns,
                    autosaveName: "ProcessLogTable",
                    key: { AnyHashable($0.id) },
                    rowStyle: { e in
                        if e.isFault { return RowStyle(background: NSColor.systemRed.withAlphaComponent(0.22)) }
                        if e.isError { return RowStyle(background: NSColor.systemOrange.withAlphaComponent(0.18)) }
                        return nil
                    },
                    menu: { rows in
                        let m = NSMenu()
                        m.add("Copy Message") { ProcessActions.copy(rows.map(\.message).joined(separator: "\n")) }
                        m.add("Copy Rows") {
                            ProcessActions.copy(rows.map { "\($0.time)\t\($0.type)\t\($0.subsystem)\t\($0.category)\t\($0.message)" }.joined(separator: "\n"))
                        }
                        if let first = rows.first, !first.subsystem.isEmpty {
                            m.addItem(.separator())
                            m.add("Filter by Subsystem “\(first.subsystem)”") { search = first.subsystem }
                        }
                        return m
                    },
                    onDoubleClick: { e in
                        Reports.show(title: "Log message — \(item.name) (\(item.pid)), \(e.time)") {
                            "\(e.time)  \(e.type)  \(e.subsystem) [\(e.category)]  \(e.sender)  thread \(e.threadID)\n\n\(e.message)"
                        }
                    },
                    defaultSort: (column: "time", ascending: true))
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Level", selection: $model.level) {
                ForEach(UnifiedLog.Level.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Default shows ordinary messages, errors and faults; Info and Debug add more detailed ones")
            Toggle(isOn: $model.paused) {
                Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
            }
            .toggleStyle(.button)
            .help(model.paused ? "Show the messages that arrived while paused, and follow new ones" : "Stop adding new messages to the list while you read")
            Button("Clear") { model.clear() }
                .help("Remove the messages shown so far")
            Menu("Earlier") {
                Button("Last 5 Minutes") { model.loadHistory(seconds: 300) }
                Button("Last 30 Minutes") { model.loadHistory(seconds: 1800) }
                Button("Last 2 Hours") { model.loadHistory(seconds: 7200) }
                Button("Since the Process Started") { model.loadSinceStart() }
            }
            .fixedSize()
            .help("Add messages the process logged before this tab was opened (log show)")
            if model.loadingHistory {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Text(status).foregroundStyle(.secondary).lineLimit(1)
            FilterField($search, width: 180)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var status: String {
        var parts = ["\(Fmt.count(rows.count)) messages"]
        if model.pendingCount > 0 { parts.append("\(Fmt.count(model.pendingCount)) waiting") }
        if model.droppedBytes > 0 { parts.append("some skipped") }
        return parts.joined(separator: " · ")
    }

    private var rows: [LogEntry] {
        let m = settings.matcher(search)
        guard !m.isEmpty else { return model.entries }
        return model.entries.filter { m.matchesAny($0.message, $0.subsystem, $0.category, $0.type, $0.sender) }
    }

    static let columns: [TableColumnSpec<LogEntry>] = [
        .number("time", "Time", width: 110, help: "When the message was logged", value: { $0.date }, text: { $0.time }),
        .string("type", "Type", width: 70,
                help: "Default, Info, Debug, Error or Fault; activities and signposts are listed too") { $0.type },
        .string("subsystem", "Subsystem", width: 170, help: "The subsystem the message was logged under, usually a reverse-DNS name") { $0.subsystem },
        .string("category", "Category", width: 100, help: "The category within the subsystem") { $0.category },
        .string("message", "Message", width: 520,
                help: "The message; double-click to read all of it. Values the process marked private read <private>") {
            $0.message.replacingOccurrences(of: "\n", with: " ⏎ ")
        },
        .string("sender", "Sender", width: 140, help: "The library or executable that logged the message") { $0.sender },
        .number("thread", "Thread", width: 80, visible: false, help: "ID of the thread that logged the message",
                value: { $0.threadID }, text: { String(format: "0x%llx", $0.threadID) }),
    ]
}
