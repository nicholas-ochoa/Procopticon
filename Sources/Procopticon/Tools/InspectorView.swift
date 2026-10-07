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
                                  size: NSSize(width: 860, height: 640)) {
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

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case loadCommands = "Load Commands"
        case segments = "Segments"
        case libraries = "Libraries"
        case symbols = "Symbols"
        case signature = "Signature"
        case infoPlist = "Info.plist"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                ContentUnavailableView("Cannot inspect file", systemImage: "doc.questionmark", description: Text(error))
            } else if let file {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: BundleInfoCache.enclosingBundlePath(path) ?? path))
                        .resizable().frame(width: 32, height: 32)
                    VStack(alignment: .leading) {
                        Text((path as NSString).lastPathComponent).font(.headline)
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if file.slices.count > 1 {
                        Picker("Architecture", selection: Binding(get: { slice ?? file.selectedSlice }, set: { slice = $0; load() })) {
                            ForEach(Array(file.slices.enumerated()), id: \.offset) { i, s in
                                Text(s.architecture).tag(i)
                            }
                        }
                        .frame(width: 200)
                    }
                }
                .padding(10)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                Divider()
                content(file)
            } else {
                ProgressView("Reading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .task { load() }
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
    private func content(_ f: MachOFile) -> some View {
        switch tab {
        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
            }
        case .loadCommands:
            OutlineTable(roots: f.loadCommands, children: nil, revision: f.loadCommands.count &+ (slice ?? 0),
                         columns: [
                             .number("index", "#", width: 40, value: { $0.index }, text: { "\($0.index)" }),
                             .string("name", "Command", width: 200) { $0.name },
                             .number("size", "Size", width: 70, value: { $0.size }, text: { "\($0.size)" }),
                             .string("summary", "Details", width: 460) { $0.summary },
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
                             .string("name", "Library", width: 420) { $0.path },
                             .string("kind", "Kind", width: 80) { $0.kind },
                             .string("current", "Current version", width: 110) { $0.currentVersion },
                             .string("compat", "Compatibility", width: 100) { $0.compatibilityVersion },
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
                    FilterField($symbolFilter, width: 260)
                    Text("\(filteredSymbols(f).count) of \(Fmt.count(f.symbols.count))").foregroundStyle(.secondary)
                }
                .padding(8)
                OutlineTable(roots: filteredSymbols(f), children: nil, revision: symbolFilter.hashValue &+ (slice ?? 0) &+ (settings.searchUsesRegex ? 1 : 0),
                             columns: [
                                 .string("name", "Name", width: 420) { $0.name },
                                 .number("addr", "Address", width: 130, value: { $0.address }, text: { $0.address == 0 ? "" : Fmt.hexAddress($0.address) }),
                                 .string("kind", "Kind", width: 140) { $0.kind },
                                 .string("ext", "Scope", width: 80) { $0.isExternal ? "External" : "Local" },
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
        .string("name", "Name", width: 220) {
            switch $0 {
            case .segment(let s): return s.name
            case .section(let s): return s.name
            }
        },
        .number("addr", "Address", width: 130, value: { r -> UInt64 in
            switch r { case .segment(let s): return s.vmAddress; case .section(let s): return s.address }
        }, text: {
            switch $0 { case .segment(let s): return Fmt.hexAddress(s.vmAddress); case .section(let s): return Fmt.hexAddress(s.address) }
        }),
        .number("size", "Size", width: 90, value: { r -> UInt64 in
            switch r { case .segment(let s): return s.vmSize; case .section(let s): return s.size }
        }, text: {
            switch $0 { case .segment(let s): return Fmt.bytes(s.vmSize); case .section(let s): return Fmt.bytes(s.size) }
        }),
        .string("prot", "Protection", width: 90) {
            if case .segment(let s) = $0 {
                return MemoryRegion.protectionString(UInt32(bitPattern: s.initProtection)) + "/" + MemoryRegion.protectionString(UInt32(bitPattern: s.maxProtection))
            }
            return ""
        },
        .string("type", "Type", width: 160) {
            if case .section(let s) = $0 { return s.typeName }
            return ""
        },
        .string("fileoff", "File offset", width: 100) {
            switch $0 {
            case .segment(let s): return Fmt.hex(s.fileOffset)
            case .section(let s): return Fmt.hex(UInt64(s.offset))
            }
        },
    ]
}
