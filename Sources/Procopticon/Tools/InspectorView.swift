import AppKit
import ProcopticonCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum InspectorWindow {
    static func open(path: String) {
        // Accept bundles: resolve to their main executable.
        var target = path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
           let exe = Bundle(path: path)?.executablePath {
            target = exe
        }
        WindowManager.shared.show(id: "inspect-\(target)", title: "\((target as NSString).lastPathComponent) — Executable Inspector",
                                  size: NSSize(width: 900, height: 640), fullSizeContent: true) {
            InspectorView(path: target)
        }
    }

    static func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an executable, library or application bundle to inspect"
        if panel.runModal() == .OK, let url = panel.url {
            open(path: url.path)
        }
    }
}

struct InspectorView: View {
    let path: String
    @State private var file: MachOFile?
    @State private var error: String?
    @State private var slice: Int?
    @State private var tab = Tab.general
    @State private var signing: SigningInfo?
    @State private var symbolFilter = ""
    @ObservedObject private var settings = AppSettings.shared

    enum Tab: String, SidebarPage {
        case general = "General"
        case loadCommands = "Load Commands"
        case segments = "Segments"
        case libraries = "Libraries"
        case symbols = "Symbols"
        case signature = "Signature"
        case infoPlist = "Info.plist"

        var id: String { rawValue }
        var title: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "info.circle"
            case .loadCommands: return "list.bullet.rectangle"
            case .segments: return "square.stack"
            case .libraries: return "books.vertical"
            case .symbols: return "function"
            case .signature: return "signature"
            case .infoPlist: return "doc.text"
            }
        }
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Cannot inspect file", systemImage: "doc.questionmark", description: Text(error))
            } else if let file {
                SidebarPagesView(selection: $tab) { tab in
                    content(file, tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } footer: {
                    if file.slices.count > 1 {
                        architecturePicker(file)
                    }
                }
            } else {
                ProgressView("Reading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .task { load() }
    }

    /// For universal files: which slice every page shows.
    private func architecturePicker(_ file: MachOFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Architecture").font(.caption).foregroundStyle(.secondary)
            Picker("Architecture", selection: Binding(get: { slice ?? file.selectedSlice }, set: { slice = $0; load() })) {
                ForEach(Array(file.slices.enumerated()), id: \.offset) { i, s in
                    Text(s.architecture).tag(i)
                }
            }
            .labelsHidden()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: BundleInfoCache.enclosingBundlePath(path) ?? path))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent).font(.title2.weight(.semibold))
                Text(path).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func load() {
        let p = path
        let s = slice
        Task.detached {
            do {
                let f = try MachOFile.load(path: p, preferredSlice: s)
                let sig = CodeSigning.inspect(path: p)
                await MainActor.run {
                    file = f
                    signing = sig
                    error = nil
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    @ViewBuilder
    private func content(_ f: MachOFile, _ tab: Tab) -> some View {
        switch tab {
        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    SectionBox(title: "Header") {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                            InfoRow("Type", f.fileTypeName)
                            InfoRow("Architecture", f.architecture)
                            InfoRow("Architectures in file", f.slices.map(\.architecture).joined(separator: ", "))
                            InfoRow("File size", Fmt.bytes(UInt64(f.fileSize)))
                            InfoRow("Flags", f.flagNames.joined(separator: ", "))
                            InfoRow("UUID", f.uuid ?? "")
                            InfoRow("Platform", f.platform ?? "")
                            InfoRow("Minimum OS", f.minOS ?? "")
                            InfoRow("SDK", f.sdk ?? "")
                            InfoRow("Source version", f.sourceVersion ?? "")
                            InfoRow("Entry point", f.entryPoint.map { Fmt.hexAddress($0) } ?? "")
                            InfoRow("Install name", f.installName ?? "")
                            InfoRow("Dynamic linker", f.dylinker ?? "")
                            InfoRow("Run paths", f.rpaths.joined(separator: "\n"))
                            InfoRow("Encrypted", f.encrypted ? "Yes" : "No")
                            InfoRow("Load commands", "\(f.loadCommands.count)")
                            InfoRow("Linked libraries", "\(f.dylibs.count)")
                            InfoRow("Symbols", Fmt.count(f.symbols.count))
                        }
                    }
                    if let signing {
                        SectionBox(title: "Code signature") {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                                InfoRow("Status", signing.verificationSummary)
                                InfoRow("Signer", signing.signer)
                                InfoRow("Team ID", signing.teamIdentifier ?? "")
                                InfoRow("Identifier", signing.identifier ?? "")
                                InfoRow("Hardened runtime", signing.hardenedRuntime ? "Yes" : "No")
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .loadCommands:
            OutlineTable(roots: f.loadCommands, children: nil, revision: f.loadCommands.count &+ (slice ?? 0),
                         columns: [
                             .number("index", "#", width: 40,
                                     help: "Position in the load command list",
                                     value: { $0.index }, text: { "\($0.index)" }),
                             .string("name", "Command", width: 200, help: "The load command's type (LC_…)") { $0.name },
                             .number("size", "Size", width: 70, help: "Size of the command in bytes", value: { $0.size }, text: { "\($0.size)" }),
                             .string("summary", "Details", width: 460, help: "What the command contains") { $0.summary },
                         ],
                         autosaveName: "InspectorLoadCommands", key: { AnyHashable($0.index) })
        case .segments:
            OutlineTable(roots: f.segments.map { SegmentRow.segment($0) }, children: { row in
                if case .segment(let s) = row { return s.sections.map { SegmentRow.section($0) } }
                return []
            }, revision: f.segments.count &+ (slice ?? 0), columns: SegmentRow.columns, autosaveName: "InspectorSegments", key: { AnyHashable($0.id) })
        case .libraries:
            OutlineTable(roots: f.dylibs, children: nil, revision: f.dylibs.count &+ (slice ?? 0),
                         columns: [
                             .string("name", "Library", width: 420, help: "Path of a library the executable links against") { $0.path },
                             .string("kind", "Kind", width: 80,
                                     help: "How it's linked: load, weak, lazy, re-export, upward, or identity (the library's own install name)") { $0.kind },
                             .string("current", "Current version", width: 110,
                                     help: "The library's current version, as recorded when the executable was linked") { $0.currentVersion },
                             .string("compat", "Compatibility", width: 100,
                                     help: "The compatibility version the library must have for the executable to load it") { $0.compatibilityVersion },
                         ],
                         autosaveName: "InspectorLibraries", key: { AnyHashable($0.id) },
                         menu: { rows in
                             let m = NSMenu()
                             if let d = rows.first, FileManager.default.fileExists(atPath: d.path) {
                                 m.add("Inspect…") { InspectorWindow.open(path: d.path) }
                             }
                             return m
                         },
                         onDoubleClick: { d in
                             if FileManager.default.fileExists(atPath: d.path) { InspectorWindow.open(path: d.path) }
                         })
        case .symbols:
            VStack(spacing: 0) {
                HStack {
                    Text("\(Fmt.count(filteredSymbols(f).count)) of \(Fmt.count(f.symbols.count)) symbols").foregroundStyle(.secondary)
                    Spacer()
                    FilterField($symbolFilter, width: 260)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
                OutlineTable(roots: filteredSymbols(f), children: nil, revision: symbolFilter.hashValue &+ (slice ?? 0) &+ (settings.searchUsesRegex ? 1 : 0),
                             columns: [
                                 .string("name", "Name", width: 420, help: "Symbol name") { $0.name },
                                 .number("addr", "Address", width: 130,
                                         help: "Symbol address; blank for undefined (imported) symbols",
                                         value: { $0.address }, text: { $0.address == 0 ? "" : Fmt.hexAddress($0.address) }),
                                 .string("kind", "Kind", width: 140,
                                         help: "Symbol type: section (defined here), undefined (imported), absolute, indirect…") { $0.kind },
                                 .string("ext", "Scope", width: 80,
                                         help: "External (visible to other images) or local") { $0.isExternal ? "External" : "Local" },
                             ],
                             autosaveName: "InspectorSymbols", key: { AnyHashable($0.index) })
            }
        case .signature:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let s = signing {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                            InfoRow("Status", s.verificationSummary)
                            InfoRow("Format", s.format ?? "")
                            InfoRow("CDHash", s.cdHash ?? "")
                            InfoRow("Flags", CodeSigningFlags.describe(s.flags).joined(separator: ", "))
                            InfoRow("Signed", s.signingDate?.formatted() ?? "")
                            InfoRow("Notarized", s.isNotarized ? "Yes" : "No")
                            InfoRow("Certificates", s.authorities.joined(separator: "\n"))
                        }
                        Text("Entitlements").font(.headline)
                        MonospacedTextView(text: s.entitlementsXML ?? "No entitlements").frame(minHeight: 260)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .infoPlist:
            MonospacedTextView(text: infoPlistText(f))
        }
    }

    private func filteredSymbols(_ f: MachOFile) -> [MachOFile.Symbol] {
        let m = settings.matcher(symbolFilter)
        if m.isEmpty { return Array(f.symbols.prefix(20000)) }
        return f.symbols.filter { m.matches($0.name) }
    }

    private func infoPlistText(_ f: MachOFile) -> String {
        if let embedded = f.embeddedInfoPlist { return embedded }
        if let bundle = BundleInfoCache.enclosingBundlePath(path) {
            for candidate in ["Contents/Info.plist", "Resources/Info.plist", "Info.plist"] {
                let p = (bundle as NSString).appendingPathComponent(candidate)
                if let data = FileManager.default.contents(atPath: p),
                   let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
                   let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) {
                    return String(decoding: xml, as: UTF8.self)
                }
            }
        }
        return "No Info.plist."
    }
}

enum SegmentRow {
    case segment(MachOFile.Segment)
    case section(MachOFile.Section)

    var id: String {
        switch self {
        case .segment(let s): return "seg-" + s.name
        case .section(let s): return "sect-" + s.id
        }
    }

    static let columns: [TableColumnSpec<SegmentRow>] = [
        .string("name", "Name", width: 220, help: "Segment or section name") {
            switch $0 {
            case .segment(let s): return s.name
            case .section(let s): return s.name
            }
        },
        .number("addr", "Address", width: 130, help: "Virtual memory address", value: { r -> UInt64 in
            switch r { case .segment(let s): return s.vmAddress; case .section(let s): return s.address }
        }, text: {
            switch $0 { case .segment(let s): return Fmt.hexAddress(s.vmAddress); case .section(let s): return Fmt.hexAddress(s.address) }
        }),
        .number("size", "Size", width: 90, help: "Size in memory", value: { r -> UInt64 in
            switch r { case .segment(let s): return s.vmSize; case .section(let s): return s.size }
        }, text: {
            switch $0 { case .segment(let s): return Fmt.bytes(s.vmSize); case .section(let s): return Fmt.bytes(s.size) }
        }),
        .string("prot", "Protection", width: 90, help: "The segment's initial / maximum protection: r = read, w = write, x = execute") {
            if case .segment(let s) = $0 {
                return MemoryRegion.protectionString(UInt32(bitPattern: s.initProtection)) + "/" + MemoryRegion.protectionString(UInt32(bitPattern: s.maxProtection))
            }
            return ""
        },
        .string("type", "Type", width: 160, help: "Section type") {
            if case .section(let s) = $0 { return s.typeName }
            return ""
        },
        .string("fileoff", "File offset", width: 100, help: "Offset of the segment or section in the file") {
            switch $0 {
            case .segment(let s): return Fmt.hex(s.fileOffset)
            case .section(let s): return Fmt.hex(UInt64(s.offset))
            }
        },
    ]
}
