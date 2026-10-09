import AppKit
import ProcopticonCore
import SwiftUI

/// Traces a process's file system calls live with fs_usage (as root).
@MainActor
final class FileActivityModel: ObservableObject {
    @Published private(set) var events: [FileEvent] = []
    @Published private(set) var files: [String: FileActivitySummary] = [:]
    @Published private(set) var revision = 0
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var error: String?
    @Published private(set) var droppedBytes = 0
    @Published var paused = false

    static let capacity = 20_000
    private let pid: Int32
    private let name: String
    private var stream: ToolStream?
    private var tracker = FileActivityTracker()
    private var nextId = 0
    /// Events that arrived since the last publish; they're published together, at most a few times
    /// a second, so a busy process doesn't redraw the table for every call.
    private var batch: [FileEvent] = []
    private var flushScheduled = false

    init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }

    func start(prompt: Bool) {
        guard stream == nil, !starting else { return }
        starting = true
        error = nil
        let pid = self.pid
        let handler: @MainActor (ToolStream.Event) -> Void = { [weak self] in self?.handle($0) }
        Task {
            // Name the files the process already has open, so reads and writes on them say which.
            let open = await Task.detached { () -> [Int32: String] in
                guard case .fileDescriptors(let fds) = Elevation.shared.perform(.fileDescriptors(pid: pid)) else { return [:] }
                return Dictionary(fds.filter { $0.type == "File" || $0.type == "Directory" }.map { ($0.fd, $0.name) },
                                  uniquingKeysWith: { a, _ in a })
            }.value
            tracker = FileActivityTracker(openFiles: open)
            let stream = ToolStream(tool: "/usr/bin/fs_usage", arguments: FileActivity.arguments(pid: pid))
            if let e = await stream.start(requiresRoot: true, prompt: prompt, handler: handler) {
                starting = false
                if e != .cancelled, !(e.isPermissionDenied && !prompt) {
                    error = e.message
                }
                return
            }
            self.stream = stream
            starting = false
            running = true
        }
    }

    func stop() {
        stream?.stop()
        stream = nil
        running = false
    }

    func clear() {
        events = []
        files = [:]
        batch = []
        droppedBytes = 0
        revision &+= 1
    }

    private func handle(_ event: ToolStream.Event) {
        switch event {
        case .lines(let lines):
            for line in lines {
                nextId += 1
                guard var e = FileActivity.parse(line, id: nextId), FileActivity.command(e.command, matches: name) else { continue }
                tracker.track(&e)
                batch.append(e)
            }
            scheduleFlush()
        case .dropped(let bytes):
            droppedBytes += bytes
        case .finished(let status, let errorOutput):
            stream = nil
            running = false
            if status != 0, !errorOutput.isEmpty {
                error = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !paused, !batch.isEmpty else {
            if batch.count > Self.capacity { batch.removeFirst(batch.count - Self.capacity) }
            return
        }
        for e in batch where !e.path.isEmpty {
            files[e.path, default: FileActivitySummary(path: e.path)].add(e)
        }
        events.append(contentsOf: batch)
        batch = []
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
        revision &+= 1
    }

    /// Shows the events held while paused.
    func resume() {
        paused = false
        flush()
    }
}

struct FileActivityTab: View {
    let item: ProcessItem
    @StateObject private var model: FileActivityModel
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("fileActivityMode") private var mode: Mode = .events
    @AppStorage("fileActivityShowAll") private var showAll = false
    @State private var search = ""

    enum Mode: String, CaseIterable, Identifiable {
        case events = "Calls"
        case files = "Files"
        var id: String { rawValue }
    }

    init(item: ProcessItem) {
        self.item = item
        _model = StateObject(wrappedValue: FileActivityModel(pid: item.pid, name: item.record.comm.isEmpty ? item.name : item.record.comm))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear {
            // Tracing needs root; start right away only when that won't ask for a password.
            if Elevation.shared.isElevated { model.start(prompt: false) }
        }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            ContentUnavailableView("Tracing stopped", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.running, !model.starting, model.events.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("Watch the files \(item.displayName) opens, reads and writes").font(.headline)
                Text("Traces the process's file system calls and disk I/O with fs_usage, which needs administrator rights.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Start Tracing") { model.start(prompt: true) }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mode == .events {
            OutlineTable(
                roots: eventRows,
                children: nil,
                revision: model.revision &+ search.hashValue &+ (showAll ? 1 : 0) &+ (settings.searchUsesRegex ? 2 : 0),
                columns: Self.eventColumns,
                autosaveName: "FileActivityTable",
                key: { AnyHashable($0.id) },
                rowStyle: { $0.errorNumber != nil ? RowStyle(background: NSColor.systemOrange.withAlphaComponent(0.16)) : nil },
                menu: { rows in fileMenu(rows.map(\.path)) },
                defaultSort: (column: "time", ascending: true))
        } else {
            OutlineTable(
                roots: fileRows,
                children: nil,
                revision: model.revision &+ search.hashValue &+ (settings.searchUsesRegex ? 2 : 0) &+ 7,
                columns: Self.fileColumns,
                autosaveName: "FileActivityFilesTable",
                key: { AnyHashable($0.path) },
                rowStyle: { $0.errors > 0 ? RowStyle(background: NSColor.systemOrange.withAlphaComponent(0.12)) : nil },
                menu: { rows in fileMenu(rows.map(\.path)) },
                defaultSort: (column: "calls", ascending: false))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.running || model.starting {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop tracing")
                    .disabled(model.starting)
            } else {
                Button { model.start(prompt: true) } label: { Label("Start", systemImage: "record.circle") }
                    .help("Trace the process's file system calls (fs_usage, as root)")
            }
            Toggle(isOn: Binding(get: { model.paused }, set: { $0 ? (model.paused = true) : model.resume() })) {
                Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
            }
            .toggleStyle(.button)
            .disabled(!model.running)
            .help("Hold new calls back while you read; they're shown when you resume")
            Button("Clear") { model.clear() }
                .help("Remove the calls shown so far")
            Picker("Show", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Calls lists each call; Files sums them up by file")
            if mode == .events {
                Toggle("Calls without a file", isOn: $showAll)
                    .toggleStyle(.checkbox)
                    .help("Also list calls that don't name a file, such as waiting for events (kevent)")
            }
            if model.starting { ProgressView().controlSize(.small) }
            Spacer()
            Text(status).foregroundStyle(.secondary).lineLimit(1)
            FilterField($search, width: 170)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var status: String {
        var parts = [mode == .events ? "\(Fmt.count(eventRows.count)) calls" : "\(Fmt.count(fileRows.count)) files"]
        if model.droppedBytes > 0 { parts.append("some skipped") }
        if model.running { parts.append("tracing") }
        return parts.joined(separator: " · ")
    }

    private var eventRows: [FileEvent] {
        let m = settings.matcher(search)
        return model.events.filter { e in
            (showAll || !e.path.isEmpty) && (m.isEmpty || m.matchesAny(e.path, e.call, e.details, e.errorDescription))
        }
    }

    private var fileRows: [FileActivitySummary] {
        let m = settings.matcher(search)
        let all = Array(model.files.values)
        return m.isEmpty ? all : all.filter { m.matches($0.path) }
    }

    private func fileMenu(_ paths: [String]) -> NSMenu {
        let m = NSMenu()
        let existing = paths.filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
        m.add("Reveal in Finder", enabled: !existing.isEmpty) {
            NSWorkspace.shared.activateFileViewerSelecting(existing.map { URL(fileURLWithPath: $0) })
        }
        m.add("Copy Path", enabled: !paths.isEmpty) { ProcessActions.copy(paths.joined(separator: "\n")) }
        if let first = paths.first, !first.isEmpty {
            m.add("Filter by This File") { search = first }
        }
        return m
    }

    private static func milliseconds(_ seconds: Double) -> String {
        seconds <= 0 ? "" : String(format: seconds < 0.001 ? "%.3f ms" : "%.2f ms", seconds * 1000)
    }

    static let eventColumns: [TableColumnSpec<FileEvent>] = {
        var path = TableColumnSpec<FileEvent>.string("path", "File", width: 400,
                                                     help: "The file the call names, or (dimmed) the file its descriptor refers to") { $0.path }
        path.attributedText = { e in
            NSAttributedString(string: e.path, attributes: e.pathFromDescriptor ? [.foregroundColor: NSColor.secondaryLabelColor] : [:])
        }
        return [
        .number("time", "Time", width: 110, help: "When the call finished", value: { $0.id }, text: { $0.time }),
        .string("call", "Call", width: 110, help: "The system call, or the disk read or write (RdData, WrMeta…)") { $0.call },
        path,
        .number("bytes", "Bytes", width: 80, help: "Bytes read or written", value: { $0.bytes ?? 0 },
                text: { $0.bytes.map { Fmt.bytes($0) } ?? "" }),
        .number("duration", "Duration", width: 80, help: "How long the call took", value: { $0.duration },
                text: { milliseconds($0.duration) + ($0.waited ? " W" : "") }),
        .string("result", "Result", width: 140, help: "The error the call failed with, if it did") { $0.errorDescription },
        .number("fd", "FD", width: 45, visible: false, help: "The file descriptor", value: { $0.descriptor ?? -1 },
                text: { $0.descriptor.map { "\($0)" } ?? "" }),
        .string("details", "Details", width: 200, help: "Open mode, offsets, fcntl command or disk device") { $0.details },
        .string("thread", "Thread", width: 90, visible: false, help: "The thread that made the call") { $0.thread },
        ]
    }()

    static let fileColumns: [TableColumnSpec<FileActivitySummary>] = [
        .string("path", "File", width: 460, help: "The file") { $0.path },
        .number("calls", "Calls", width: 70, help: "Calls on the file since tracing started", value: { $0.calls }, text: { Fmt.count($0.calls) }),
        .number("read", "Read", width: 90, help: "Bytes read from the file", value: { $0.bytesRead },
                text: { $0.bytesRead > 0 ? Fmt.bytes($0.bytesRead) : "" }),
        .number("written", "Written", width: 90, help: "Bytes written to the file", value: { $0.bytesWritten },
                text: { $0.bytesWritten > 0 ? Fmt.bytes($0.bytesWritten) : "" }),
        .number("errors", "Errors", width: 60, help: "Calls on the file that failed", value: { $0.errors },
                text: { $0.errors > 0 ? "\($0.errors)" : "" }),
        .string("last", "Last call", width: 170, help: "The latest call on the file and when it happened") { "\($0.lastCall) at \($0.lastTime)" },
    ]
}
