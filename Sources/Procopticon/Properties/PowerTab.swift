import AppKit
import ProcopticonCore
import SwiftUI

/// The process's power assertions: what it does to keep the Mac or the display awake.
struct PowerTab: View {
    let item: ProcessItem
    let revision: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label(sleepSummary, systemImage: item.sleepPrevention == nil ? "moon.zzz" : "cup.and.saucer")
                    .foregroundStyle(item.sleepPrevention == nil ? Color.secondary : Color.orange)
                Text("Power: \(Fmt.watts(item.power).ifEmpty("0 W"))").foregroundStyle(.secondary)
                Text("Wake-ups: \(Fmt.count(max(0, Int(item.wakeupsDelta))))").foregroundStyle(.secondary)
                    .help("Times the process woke a CPU over the last update interval")
                Spacer()
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            if item.assertions.isEmpty {
                ContentUnavailableView("No power assertions", systemImage: "bolt.slash",
                                       description: Text("The process isn't keeping the Mac or its display awake, and no other process is doing so on its behalf."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OutlineTable(
                    roots: item.assertions,
                    children: nil,
                    revision: revision,
                    columns: columns,
                    autosaveName: "PowerAssertionsTable",
                    key: { AnyHashable("\($0.ownerPid)-\($0.id)") },
                    menu: { rows in
                        let m = NSMenu()
                        m.add("Copy Name") { ProcessActions.copy(rows.map(\.name).joined(separator: "\n")) }
                        if let owner = rows.first?.ownerPid, owner != item.pid {
                            m.add("Show Holding Process") { ProcessSelection.shared.reveal(pid: owner) }
                        }
                        return m
                    },
                    defaultSort: (column: "started", ascending: true))
            }
        }
    }

    private var sleepSummary: String {
        switch item.sleepPrevention {
        case .display?: return "Keeping the display on"
        case .system?: return "Keeping the Mac awake"
        case nil: return "Not preventing sleep"
        }
    }

    private var columns: [TableColumnSpec<PowerAssertion>] {
        let pid = item.pid
        return [
            .string("type", "Type", width: 190,
                    help: "The kind of assertion; a legacy name the process used is shown in parentheses") { a in
                a.requestedType.map { "\(a.type) (\($0))" } ?? a.type
            },
            .string("effect", "Effect", width: 200, help: "What the assertion does") { $0.isOn ? $0.typeDescription : "Off" },
            .string("name", "Name", width: 220, help: "The name the process gave the assertion") { $0.name },
            .number("started", "Started", width: 140, help: "When the assertion was created",
                    value: { $0.started ?? .distantPast }, text: { $0.started.map { Fmt.date($0.timeIntervalSince1970) } ?? "" }),
            .number("held", "Held for", width: 90, help: "How long the assertion has been held",
                    value: { -($0.started?.timeIntervalSince1970 ?? 0) },
                    text: { $0.started.map { Fmt.relative(seconds: Date().timeIntervalSince($0)) } ?? "" }),
            .number("timeout", "Time left", width: 80, visible: false,
                    help: "Seconds until the assertion's timeout releases it, for assertions with a timeout",
                    value: { $0.timeLeft ?? .infinity }, text: { a in a.timeLeft.map { "\(Int($0))s" } ?? "" }),
            .string("holder", "Held by", width: 140,
                    help: "The process holding the assertion, when another holds it on this process's behalf") { a in
                guard a.ownerPid != pid else { return "" }
                return ProcessStore.shared.item(pid: a.ownerPid).map { "\($0.name) (\(a.ownerPid))" } ?? "\(a.ownerPid)"
            },
            .string("details", "Details", width: 260, help: "Details and the reason shown to users, if the process gave them") { a in
                [a.details, a.reason].compactMap { $0 }.joined(separator: " — ")
            },
        ]
    }
}
