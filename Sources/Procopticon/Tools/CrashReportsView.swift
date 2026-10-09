import AppKit
import ProcopticonCore
import SwiftUI

// MARK: - Window

@MainActor
enum CrashReportsWindow {
    static func open() {
        WindowManager.shared.show(id: "crashReports", title: "Crash Reports", size: NSSize(width: 980, height: 560), autosave: "CrashReports") {
            CrashReportsView()
        }
    }

    /// Shows a report in a text window: a JSON crash report laid out as a classic crash log.
    static func show(_ report: DiagnosticReport) {
        let path = report.path
        Reports.show(title: "\(report.processName) — \(report.kind.rawValue), \(Fmt.date(report.date.timeIntervalSince1970))", id: "report-\(path)") {
            await Task.detached { DiagnosticReports.readableText(path: path) }.value
        }
    }

    static func openInConsole(_ reports: [DiagnosticReport]) {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(reports.map { URL(fileURLWithPath: $0.path) }, withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    static func menu(_ reports: [DiagnosticReport]) -> NSMenu {
        let m = NSMenu()
        guard let first = reports.first else { return m }
        m.add("Show Report") { show(first) }
        m.add("Open in Console") { openInConsole(reports) }
        m.add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(reports.map { URL(fileURLWithPath: $0.path) }) }
        m.add("Copy Path") { ProcessActions.copy(reports.map(\.path).joined(separator: "\n")) }
        if let pid = first.pid, let running = ProcessStore.shared.item(pid: pid), running.name == first.processName {
            m.addItem(.separator())
            m.add("Show Process") { ProcessSelection.shared.reveal(pid: running.pid) }
        }
        return m
    }
}

/// Which reports a list shows.
enum ReportKindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case crashes = "Crashes"
    case hangs = "Hangs"
    case resources = "Resource Use"
    case memory = "Memory"
    var id: String { rawValue }

    func includes(_ r: DiagnosticReport) -> Bool {
        switch self {
        case .all: return true
        case .crashes: return r.kind.isCrash || r.kind == .exception
        case .hangs: return r.kind == .hang || r.kind == .shutdownStall
        case .resources: return r.kind.isResourceReport
        case .memory: return r.kind == .memory
        }
    }
}

/// Loads reports off the main thread; shared by the window and the Properties tab.
@MainActor
final class DiagnosticReportsModel: ObservableObject {
    @Published private(set) var reports: [DiagnosticReport] = []
    @Published private(set) var loading = false
    @Published private(set) var revision = 0

    func load() {
        loading = true
        Task {
            let list = await Task.detached { DiagnosticReports.all() }.value
            reports = list
            loading = false
            revision &+= 1
        }
    }
}

/// A row of the grouped list: a process with its reports, or one report.
final class ReportRow {
    let key: String
    let name: String
    let report: DiagnosticReport?
    let children: [ReportRow]

    init(report: DiagnosticReport) {
        key = report.path
        name = report.processName
        self.report = report
        children = []
    }

    init(name: String, reports: [DiagnosticReport]) {
        key = "group:" + name
        self.name = name
        report = nil
        children = reports.map(ReportRow.init(report:))
    }

    /// The newest report in the row.
    var latest: DiagnosticReport? { report ?? children.first?.report }
    var count: Int { report == nil ? children.count : 1 }
}

// MARK: - All reports

struct CrashReportsView: View {
    @StateObject private var model = DiagnosticReportsModel()
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("crashReportsKind") private var kind: ReportKindFilter = .crashes
    @AppStorage("crashReportsGrouped") private var grouped = true
    @State private var search = ""

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $kind) {
                    ForEach(ReportKindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Crashes include exceptions; Resource Use covers reports of excessive CPU use, disk writes and wake-ups; Memory lists processes killed for using too much memory")
                Toggle("Group by process", isOn: $grouped)
                    .toggleStyle(.checkbox)
                    .help("List each process once, with its reports under it, so the ones that keep crashing stand out")
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(Fmt.count(rows.reduce(0) { $0 + $1.count })) reports").foregroundStyle(.secondary)
                FilterField($search, width: 200)
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the report folders again")
            }
            .padding(8)
            Divider()
            OutlineTable(
                roots: rows,
                children: { $0.children },
                revision: model.revision &+ search.hashValue &+ kind.hashValue &+ (grouped ? 1 : 0) &+ (settings.searchUsesRegex ? 2 : 0),
                columns: Self.columns,
                autosaveName: "CrashReportsTable",
                key: { AnyHashable($0.key) },
                menu: { rows in CrashReportsWindow.menu(rows.flatMap { $0.report.map { [$0] } ?? $0.children.compactMap(\.report) }) },
                onDoubleClick: { row in if let r = row.report { CrashReportsWindow.show(r) } },
                defaultSort: (column: "date", ascending: false),
                expandByDefault: false)
            Divider()
            Text("Reports from ~/Library/Logs/DiagnosticReports and /Library/Logs/DiagnosticReports, including those already sent (Retired). Double-click one to read it.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.load() }
    }

    private var rows: [ReportRow] {
        let m = settings.matcher(search)
        let reports = model.reports.filter { r in
            kind.includes(r) && (m.isEmpty || m.matchesAny(r.processName, r.summary, r.bundleIdentifier, r.executablePath, r.fileName)
                || r.killedProcesses.contains { m.matches($0) })
        }
        guard grouped else { return reports.map(ReportRow.init(report:)) }
        let byName = Dictionary(grouping: reports, by: \.processName)
        return byName.map { ReportRow(name: $0.key, reports: $0.value.sorted { $0.date > $1.date }) }
    }

    static let columns: [TableColumnSpec<ReportRow>] = [
        .string("process", "Process", width: 220, help: "The process the report is about; for a group, how many reports it has") { row in
            row.report == nil ? "\(row.name) (\(row.count))" : row.name
        },
        .number("count", "Reports", width: 60, visible: false, help: "Number of reports for the process",
                value: { $0.count }, text: { $0.report == nil ? "\($0.count)" : "" }),
        .string("kind", "Kind", width: 100,
                help: "Crash, exception, hang, excessive resource use (CPU, disk writes, wake-ups) or a jetsam memory kill") { row in
            guard let r = row.report else {
                let kinds = Set(row.children.compactMap { $0.report?.kind })
                return kinds.count == 1 ? kinds.first!.rawValue : "Mixed"
            }
            return r.kind.rawValue
        },
        .number("date", "Date", width: 150, help: "When the report was written; for a group, the latest",
                value: { $0.latest?.date ?? .distantPast }, text: { $0.latest.map { Fmt.date($0.date.timeIntervalSince1970) } ?? "" }),
        .string("summary", "Summary", width: 320, help: "The exception and signal of a crash, or what a resource report measured") {
            $0.report?.summary ?? ""
        },
        .string("version", "Version", width: 90, help: "The app's version when the report was written") { $0.latest?.version ?? "" },
        .string("bundle", "Bundle identifier", width: 170, visible: false, help: "The app's bundle identifier") { $0.latest?.bundleIdentifier ?? "" },
        .string("path", "Executable", width: 300, visible: false, help: "The crashed executable's path") { $0.report?.executablePath ?? "" },
        .string("file", "File", width: 260, visible: false, help: "The report file; Retired reports have already been sent or aged out") { row in
            guard let r = row.report else { return "" }
            return r.isRetired ? "Retired/\(r.fileName)" : r.fileName
        },
    ]
}

// MARK: - One process's reports

struct ProcessReportsTab: View {
    let item: ProcessItem
    @StateObject private var model = DiagnosticReportsModel()

    var body: some View {
        let reports = model.reports.filter {
            $0.concerns(path: item.record.path, name: item.name, bundleIdentifier: item.bundleInfo?.bundleIdentifier)
        }
        VStack(spacing: 0) {
            HStack {
                Text(summary(reports)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("All Crash Reports…") { CrashReportsWindow.open() }
                    .help("Show the reports of every process")
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the report folders again")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            if reports.isEmpty, !model.loading {
                ContentUnavailableView("No reports", systemImage: "checkmark.seal",
                                       description: Text("macOS has no crash, hang or resource reports for \(item.displayName)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OutlineTable(
                    roots: reports.map(ReportRow.init(report:)),
                    children: nil,
                    revision: model.revision,
                    columns: CrashReportsView.columns.filter { $0.id != "process" && $0.id != "count" },
                    autosaveName: "ProcessReportsTable",
                    key: { AnyHashable($0.key) },
                    menu: { rows in CrashReportsWindow.menu(rows.compactMap(\.report)) },
                    onDoubleClick: { row in if let r = row.report { CrashReportsWindow.show(r) } },
                    defaultSort: (column: "date", ascending: false))
            }
        }
        .onAppear { model.load() }
    }

    private func summary(_ reports: [DiagnosticReport]) -> String {
        let crashes = reports.filter { $0.kind.isCrash || $0.kind == .exception }
        let week = crashes.filter { Date().timeIntervalSince($0.date) < 7 * 86_400 }
        var parts = ["\(reports.count) \(reports.count == 1 ? "report" : "reports")"]
        if !crashes.isEmpty {
            parts.append("\(crashes.count) \(crashes.count == 1 ? "crash" : "crashes") (\(week.count) in the last 7 days)")
        }
        return parts.joined(separator: " · ")
    }
}
