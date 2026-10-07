import AppKit
import ProcopticonCore
import SwiftUI

/// A named combination of search text and process filters.
struct SavedFilter: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var text: String = ""
    var regex = false
    var onlyApplications = false
    var onlyMine = false
    var hideSystem = false
    var hideApple = false
    var hideZombies = false
    /// nil leaves the current tree/list mode unchanged.
    var treeView: Bool?

    /// Same filtering effect, ignoring identity, name and view mode.
    func matchesState(of other: SavedFilter) -> Bool {
        text.trimmingCharacters(in: .whitespaces) == other.text.trimmingCharacters(in: .whitespaces)
            && regex == other.regex && onlyApplications == other.onlyApplications && onlyMine == other.onlyMine
            && hideSystem == other.hideSystem && hideApple == other.hideApple && hideZombies == other.hideZombies
    }

    var summary: String {
        var parts: [String] = []
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { parts.append(regex ? "regex \(t)" : "“\(t)”") }
        if onlyApplications { parts.append("apps") }
        if onlyMine { parts.append("mine") }
        if hideSystem { parts.append("no system") }
        if hideApple { parts.append("no Apple") }
        if hideZombies { parts.append("no zombies") }
        if let treeView { parts.append(treeView ? "tree" : "list") }
        return parts.isEmpty ? "No filtering" : parts.joined(separator: " · ")
    }

    static let defaults: [SavedFilter] = [
        SavedFilter(name: "My Applications", onlyApplications: true, onlyMine: true),
        SavedFilter(name: "Third-Party Processes", hideApple: true),
        SavedFilter(name: "Root Processes", text: "/^root$/", treeView: false),
        SavedFilter(name: "Helpers & XPC Services", text: "\\.xpc/|helper", regex: true),
    ]
}

extension AppSettings {
    /// Snapshot of the current filters as an unsaved filter.
    func currentFilter(name: String = "Untitled Filter") -> SavedFilter {
        SavedFilter(name: name, text: ProcessStore.shared.filter.text, regex: searchUsesRegex,
                    onlyApplications: onlyApplications, onlyMine: hideOtherUsers, hideSystem: hideSystemProcesses,
                    hideApple: hideAppleProcesses, hideZombies: hideZombies, treeView: nil)
    }

    func applySavedFilter(_ f: SavedFilter) {
        searchUsesRegex = f.regex
        onlyApplications = f.onlyApplications
        hideOtherUsers = f.onlyMine
        hideSystemProcesses = f.hideSystem
        hideAppleProcesses = f.hideApple
        hideZombies = f.hideZombies
        if let tree = f.treeView {
            treeView = tree
        }
        NotificationCenter.default.post(name: .showTab, object: MainTab.processes)
        ProcessStore.shared.filter.text = f.text
    }

    /// The saved filter equivalent to the current state, if any.
    var activeSavedFilter: SavedFilter? {
        let current = currentFilter()
        return savedFilters.first { $0.matchesState(of: current) && current.isNonTrivial }
    }

    @MainActor
    func saveCurrentFilterInteractively() {
        guard let name = Alerts.prompt("Save Filter", message: "Name for the current search and filters:", defaultValue: "", button: "Save"),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        savedFilters.append(currentFilter(name: name.trimmingCharacters(in: .whitespaces)))
    }
}

private extension SavedFilter {
    var isNonTrivial: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || onlyApplications || onlyMine || hideSystem || hideApple || hideZombies
    }
}

/// Menu items listing saved filters (used in the toolbar Filters menu and the View menu).
struct SavedFiltersMenuItems: View {
    @ObservedObject private var settings = AppSettings.shared
    var shortcuts = false

    var body: some View {
        let active = settings.activeSavedFilter?.id
        ForEach(Array(settings.savedFilters.enumerated()), id: \.element.id) { index, f in
            let button = Button {
                settings.applySavedFilter(f)
            } label: {
                if active == f.id {
                    Label(f.name, systemImage: "checkmark")
                } else {
                    Text(f.name)
                }
            }
            if shortcuts, index < 9 {
                button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
            } else {
                button
            }
        }
        if !settings.savedFilters.isEmpty {
            Divider()
        }
        Button("Save Current Filter…") { settings.saveCurrentFilterInteractively() }
        Button("Manage Saved Filters…") { SettingsOpener.open(tab: .filters) }
    }
}

// MARK: - Settings tab

struct SavedFiltersSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: SavedFilter.ID?

    var body: some View {
        // Plain stacks rather than HSplitView: an AppKit split view ignores the Settings window's
        // toolbar, so its divider ran up through the title bar and the editor scrolled under the tabs.
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.savedFilters) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name)
                            Text(f.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(f.id)
                    }
                    .onMove { settings.savedFilters.move(fromOffsets: $0, toOffset: $1) }
                }
                .scrollContentBackground(.hidden)
                Divider()
                HStack(spacing: 2) {
                    Button { addFromCurrent() } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                        .help("New filter from the current search and filters")
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                        .disabled(selection == nil)
                        .help("Delete the selected filter")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square").frame(width: 22, height: 20) }
                        .disabled(selection == nil)
                        .help("Duplicate the selected filter")
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 20) }
                        .disabled(!canMove(-1))
                        .help("Move up")
                    Button { move(1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 20) }
                        .disabled(!canMove(1))
                        .help("Move down")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(width: 210)
            .padding([.leading, .vertical], 20)

            Group {
                if let index = settings.savedFilters.firstIndex(where: { $0.id == selection }) {
                    SavedFilterEditor(filter: $settings.savedFilters[index])
                } else {
                    VStack(spacing: 8) {
                        Text("Select a filter to edit it.").foregroundStyle(.secondary)
                        Text("Saved filters appear in the toolbar's Filters menu and in View ▸ Saved Filters (⌃⌘1–9).")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Restore Example Filters") {
                            for f in SavedFilter.defaults where !settings.savedFilters.contains(where: { $0.name == f.name }) {
                                settings.savedFilters.append(f)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .settingsPaneBackground()
        .onAppear {
            if selection == nil { selection = settings.savedFilters.first?.id }
        }
    }

    private func addFromCurrent() {
        var f = settings.currentFilter(name: "New Filter")
        f.id = UUID()
        settings.savedFilters.append(f)
        selection = f.id
    }

    private func remove() {
        guard let i = settings.savedFilters.firstIndex(where: { $0.id == selection }) else { return }
        settings.savedFilters.remove(at: i)
        selection = settings.savedFilters.indices.contains(i) ? settings.savedFilters[i].id : settings.savedFilters.last?.id
    }

    private func duplicate() {
        guard let f = settings.savedFilters.first(where: { $0.id == selection }) else { return }
        var copy = f
        copy.id = UUID()
        copy.name = f.name + " Copy"
        settings.savedFilters.append(copy)
        selection = copy.id
    }

    private func canMove(_ delta: Int) -> Bool {
        guard let i = settings.savedFilters.firstIndex(where: { $0.id == selection }) else { return false }
        return settings.savedFilters.indices.contains(i + delta)
    }

    private func move(_ delta: Int) {
        guard let i = settings.savedFilters.firstIndex(where: { $0.id == selection }), canMove(delta) else { return }
        settings.savedFilters.swapAt(i, i + delta)
    }
}

struct SavedFilterEditor: View {
    @Binding var filter: SavedFilter

    var body: some View {
        let matcher = SearchMatcher(filter.text, regex: filter.regex)
        VStack(spacing: 0) {
            form(matcher)
            // Outside the scrolling form so it stays visible however long the form gets.
            HStack {
                Spacer()
                Button("Apply Now") { AppSettings.shared.applySavedFilter(filter) }
                    .disabled(!matcher.isValid)
                    .help("Apply this filter to the process list")
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    private func form(_ matcher: SearchMatcher) -> some View {
        Form {
            TextField("Name", text: $filter.name)
            Section("Search") {
                TextField("Search text", text: $filter.text, prompt: Text("name, PID, path, command line, user…"))
                Toggle("Regular expression", isOn: $filter.regex)
                if let error = matcher.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                } else {
                    Text("Text written as /pattern/ is always a regular expression; /pattern/c is case-sensitive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Show") {
                Toggle("Only GUI applications and their child processes", isOn: $filter.onlyApplications)
                Toggle("Only my processes", isOn: $filter.onlyMine)
                Toggle("Hide root & system processes", isOn: $filter.hideSystem)
                Toggle("Hide Apple-signed processes", isOn: $filter.hideApple)
                Toggle("Hide zombie processes", isOn: $filter.hideZombies)
                Picker("View", selection: $filter.treeView) {
                    Text("Keep current").tag(Bool?.none)
                    Text("Tree").tag(Bool?.some(true))
                    Text("List").tag(Bool?.some(false))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
