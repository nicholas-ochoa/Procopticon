import Foundation
import MachO

/// Minimal Mach-O reader for the executable inspector.
public struct MachOFile: Sendable {
    public struct Slice: Sendable, Identifiable {
        public var id: Int { offset }
        public var cpuType: Int32
        public var cpuSubtype: Int32
        public var offset: Int
        public var size: Int
        public var architecture: String { MachOFile.archName(cpuType, cpuSubtype) }
    }

    public struct Section: Sendable, Identifiable, Hashable {
        public var id: String { "\(segment),\(name)" }
        public var name: String
        public var segment: String
        public var address: UInt64
        public var size: UInt64
        public var offset: UInt32
        public var flags: UInt32
        public var typeName: String {
            switch flags & 0xff {
            case 0x0: return "Regular"
            case 0x1: return "Zero fill"
            case 0x2: return "C strings"
            case 0x6: return "Non-lazy pointers"
            case 0x7: return "Lazy pointers"
            case 0x8: return "Symbol stubs"
            case 0x9: return "Init function pointers"
            case 0xa: return "Term function pointers"
            case 0xc: return "Zero fill (GB)"
            case 0xd: return "Interposing"
            case 0xe: return "16-byte literals"
            case 0x10: return "Lazy dylib pointers"
            case 0x11: return "Thread-local regular"
            case 0x12: return "Thread-local zero fill"
            case 0x13: return "Thread-local variables"
            case 0x15: return "Thread-local init pointers"
            default: return String(format: "Type 0x%x", flags & 0xff)
            }
        }
    }

    public struct Segment: Sendable, Identifiable, Hashable {
        public var id: String { name }
        public var name: String
        public var vmAddress: UInt64
        public var vmSize: UInt64
        public var fileOffset: UInt64
        public var fileSize: UInt64
        public var maxProtection: Int32
        public var initProtection: Int32
        public var sections: [Section]
    }

    public struct Dylib: Sendable, Identifiable, Hashable {
        public var id: String { "\(kind)-\(path)" }
        public var path: String
        public var kind: String
        public var currentVersion: String
        public var compatibilityVersion: String
    }

    public struct LoadCommand: Sendable, Identifiable, Hashable {
        public var id: Int { index }
        public var index: Int
        public var name: String
        public var size: UInt32
        public var summary: String
    }

    public struct Symbol: Sendable, Identifiable, Hashable {
        public var id: Int { index }
        public var index: Int
        public var name: String
        public var address: UInt64
        public var kind: String
        public var isExternal: Bool
        public var section: UInt8
    }

    public var path: String
    public var fileSize: Int
    public var slices: [Slice]
    public var selectedSlice: Int
    public var cpuType: Int32 = 0
    public var cpuSubtype: Int32 = 0
    public var fileType: UInt32 = 0
    public var flags: UInt32 = 0
    public var uuid: String?
    public var platform: String?
    public var minOS: String?
    public var sdk: String?
    public var sourceVersion: String?
    public var entryPoint: UInt64?
    public var dylinker: String?
    public var installName: String?
    public var rpaths: [String] = []
    public var segments: [Segment] = []
    public var dylibs: [Dylib] = []
    public var loadCommands: [LoadCommand] = []
    public var symbols: [Symbol] = []
    public var codeSignatureSize: UInt32 = 0
    public var encrypted = false
    public var embeddedInfoPlist: String?

    public var architecture: String { Self.archName(cpuType, cpuSubtype) }

    public var fileTypeName: String {
        switch fileType {
        case 0x1: return "Object file"
        case 0x2: return "Executable"
        case 0x3: return "Fixed VM shared library"
        case 0x4: return "Core dump"
        case 0x5: return "Preloaded executable"
        case 0x6: return "Dynamic library"
        case 0x7: return "Dynamic linker"
        case 0x8: return "Bundle"
        case 0x9: return "Dylib stub"
        case 0xa: return "Debug symbols (dSYM)"
        case 0xb: return "Kernel extension"
        case 0xc: return "Fileset"
        default: return String(format: "0x%x", fileType)
        }
    }

    public var flagNames: [String] {
        let table: [(UInt32, String)] = [
            (0x1, "NOUNDEFS"), (0x4, "DYLDLINK"), (0x8, "BINDATLOAD"), (0x10, "PREBOUND"),
            (0x80, "TWOLEVEL"), (0x100, "FORCE_FLAT"), (0x200, "NOMULTIDEFS"), (0x2000, "SUBSECTIONS_VIA_SYMBOLS"),
            (0x8000, "WEAK_DEFINES"), (0x10000, "BINDS_TO_WEAK"), (0x20000, "ALLOW_STACK_EXECUTION"),
            (0x40000, "ROOT_SAFE"), (0x80000, "SETUID_SAFE"), (0x100000, "NO_REEXPORTED_DYLIBS"), (0x200000, "PIE"),
            (0x800000, "HAS_TLV_DESCRIPTORS"), (0x1000000, "NO_HEAP_EXECUTION"), (0x2000000, "APP_EXTENSION_SAFE"),
            (0x4000000, "NLIST_OUTOFSYNC_WITH_DYLDINFO"), (0x8000000, "SIM_SUPPORT"), (0x80000000, "DYLIB_IN_CACHE"),
        ]
        return table.filter { flags & $0.0 != 0 }.map(\.1)
    }

    public static func archName(_ type: Int32, _ subtype: Int32) -> String {
        switch type {
        case CPU_TYPE_ARM64:
            return (subtype & 0xff) == 2 ? "arm64e" : "arm64"
        case CPU_TYPE_X86_64:
            return (subtype & 0xff) == 8 ? "x86_64h" : "x86_64"
        case CPU_TYPE_ARM: return "arm"
        case CPU_TYPE_X86: return "i386"
        case CPU_TYPE_ARM64_32: return "arm64_32"
        case CPU_TYPE_POWERPC: return "ppc"
        default: return "cpu \(type)"
        }
    }

    public enum ParseError: Error, LocalizedError {
        case unreadable(String)
        case notMachO
        public var errorDescription: String? {
            switch self {
            case .unreadable(let s): return "Unable to read file: \(s)"
            case .notMachO: return "Not a Mach-O file."
            }
        }
    }

    public static func load(path: String, preferredSlice: Int? = nil, maxSymbols: Int = 200_000) throws -> MachOFile {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw ParseError.unreadable(error.localizedDescription)
        }
        guard data.count >= 8 else { throw ParseError.notMachO }
        var file = MachOFile(path: path, fileSize: data.count, slices: [], selectedSlice: 0)
        let magicBE = data.be32(0)
        if magicBE == FAT_MAGIC || magicBE == FAT_MAGIC_64 {
            let count = Int(data.be32(4))
            let is64 = magicBE == FAT_MAGIC_64
            for i in 0..<min(count, 64) {
                let base = 8 + i * (is64 ? 32 : 20)
                guard base + 20 <= data.count else { break }
                let type = Int32(bitPattern: data.be32(base))
                let sub = Int32(bitPattern: data.be32(base + 4))
                // Clamped: a damaged or hostile file can say anything here, and what doesn't fit the
                // file is turned down when the slice is parsed.
                let offset = is64 ? Int(clamping: data.be64(base + 8)) : Int(data.be32(base + 8))
                let size = is64 ? Int(clamping: data.be64(base + 16)) : Int(data.be32(base + 12))
                file.slices.append(Slice(cpuType: type, cpuSubtype: sub, offset: offset, size: size))
            }
        } else {
            let magic = data.le32(0)
            guard magic == MH_MAGIC_64 || magic == MH_MAGIC else { throw ParseError.notMachO }
            file.slices.append(Slice(cpuType: Int32(bitPattern: data.le32(4)), cpuSubtype: Int32(bitPattern: data.le32(8)), offset: 0, size: data.count))
        }
        guard !file.slices.isEmpty else { throw ParseError.notMachO }
        var index = preferredSlice ?? 0
        if preferredSlice == nil {
            #if arch(arm64)
            index = file.slices.firstIndex { $0.cpuType == CPU_TYPE_ARM64 } ?? 0
            #else
            index = file.slices.firstIndex { $0.cpuType == CPU_TYPE_X86_64 } ?? 0
            #endif
        }
        file.selectedSlice = min(index, file.slices.count - 1)
        try file.parseSlice(data, file.slices[file.selectedSlice], maxSymbols: maxSymbols)
        return file
    }

    private mutating func parseSlice(_ data: Data, _ slice: Slice, maxSymbols: Int) throws {
        let base = slice.offset
        guard base >= 0, base <= data.count - 28 else { throw ParseError.notMachO }
        let magic = data.le32(base)
        let is64 = magic == MH_MAGIC_64
        guard is64 || magic == MH_MAGIC else { throw ParseError.notMachO }
        cpuType = Int32(bitPattern: data.le32(base + 4))
        cpuSubtype = Int32(bitPattern: data.le32(base + 8))
        fileType = data.le32(base + 12)
        let ncmds = Int(data.le32(base + 16))
        flags = data.le32(base + 24)
        var cursor = base + (is64 ? 32 : 28)
        var textVMAddr: UInt64 = 0
        var symtab: (symoff: Int, nsyms: Int, stroff: Int, strsize: Int)?

        for i in 0..<min(ncmds, 4096) {
            guard cursor + 8 <= data.count else { break }
            let cmd = data.le32(cursor)
            let size = data.le32(cursor + 4)
            guard size >= 8 else { break }
            var name = String(format: "0x%x", cmd)
            var summary = ""
            switch cmd {
            case UInt32(LC_SEGMENT_64), UInt32(LC_SEGMENT):
                let s64 = cmd == UInt32(LC_SEGMENT_64)
                name = s64 ? "LC_SEGMENT_64" : "LC_SEGMENT"
                let segname = data.cString(cursor + 8, max: 16)
                let vmaddr = s64 ? data.le64(cursor + 24) : UInt64(data.le32(cursor + 24))
                let vmsize = s64 ? data.le64(cursor + 32) : UInt64(data.le32(cursor + 28))
                let fileoff = s64 ? data.le64(cursor + 40) : UInt64(data.le32(cursor + 32))
                let filesize = s64 ? data.le64(cursor + 48) : UInt64(data.le32(cursor + 36))
                let maxprot = Int32(bitPattern: data.le32(cursor + (s64 ? 56 : 40)))
                let initprot = Int32(bitPattern: data.le32(cursor + (s64 ? 60 : 44)))
                let nsects = Int(data.le32(cursor + (s64 ? 64 : 48)))
                var sections: [Section] = []
                var sp = cursor + (s64 ? 72 : 56)
                for _ in 0..<min(nsects, 256) {
                    guard sp + (s64 ? 80 : 68) <= data.count else { break }
                    let sect = data.cString(sp, max: 16)
                    let seg = data.cString(sp + 16, max: 16)
                    let addr = s64 ? data.le64(sp + 32) : UInt64(data.le32(sp + 32))
                    let ssize = s64 ? data.le64(sp + 40) : UInt64(data.le32(sp + 36))
                    let off = data.le32(sp + (s64 ? 48 : 40))
                    let sflags = data.le32(sp + (s64 ? 64 : 56))
                    sections.append(Section(name: sect, segment: seg, address: addr, size: ssize, offset: off, flags: sflags))
                    let start = base + Int(off)
                    let length = Int(clamping: ssize)
                    // The first one, and of a size an Info.plist has: a crafted file can carry
                    // thousands of these sections, each claiming the whole file.
                    if seg == "__TEXT", sect == "__info_plist", embeddedInfoPlist == nil, off > 0, length <= 4 << 20,
                       start <= data.count, length <= data.count - start {
                        embeddedInfoPlist = String(decoding: data[start..<(start + length)], as: UTF8.self)
                    }
                    sp += s64 ? 80 : 68
                }
                if segname == "__TEXT" { textVMAddr = vmaddr }
                segments.append(Segment(name: segname, vmAddress: vmaddr, vmSize: vmsize, fileOffset: fileoff, fileSize: filesize,
                                        maxProtection: maxprot, initProtection: initprot, sections: sections))
                summary = "\(segname)  \(Fmt.hexAddress(vmaddr))  \(Fmt.bytes(vmsize))  \(sections.count) sections"
            case UInt32(LC_LOAD_DYLIB), LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, UInt32(LC_LAZY_LOAD_DYLIB), LC_LOAD_UPWARD_DYLIB, UInt32(LC_ID_DYLIB):
                let kinds: [UInt32: (String, String)] = [
                    UInt32(LC_LOAD_DYLIB): ("LC_LOAD_DYLIB", "Load"), LC_LOAD_WEAK_DYLIB: ("LC_LOAD_WEAK_DYLIB", "Weak"),
                    LC_REEXPORT_DYLIB: ("LC_REEXPORT_DYLIB", "Re-export"), UInt32(LC_LAZY_LOAD_DYLIB): ("LC_LAZY_LOAD_DYLIB", "Lazy"),
                    LC_LOAD_UPWARD_DYLIB: ("LC_LOAD_UPWARD_DYLIB", "Upward"), UInt32(LC_ID_DYLIB): ("LC_ID_DYLIB", "Identity"),
                ]
                let k = kinds[cmd] ?? ("LC_DYLIB", "Load")
                name = k.0
                let nameOffset = Int(data.le32(cursor + 8))
                let path = data.cString(cursor + nameOffset, max: Int(size) - nameOffset)
                let current = Self.version(data.le32(cursor + 16))
                let compat = Self.version(data.le32(cursor + 20))
                if cmd == UInt32(LC_ID_DYLIB) {
                    installName = path
                } else {
                    dylibs.append(Dylib(path: path, kind: k.1, currentVersion: current, compatibilityVersion: compat))
                }
                summary = "\(path) (\(current))"
            case LC_RPATH:
                name = "LC_RPATH"
                let off = Int(data.le32(cursor + 8))
                let p = data.cString(cursor + off, max: Int(size) - off)
                rpaths.append(p)
                summary = p
            case UInt32(LC_UUID):
                name = "LC_UUID"
                if cursor + 24 <= data.count {
                    let bytes = data[(cursor + 8)..<(cursor + 24)]
                    let u = NSUUID(uuidBytes: Array(bytes)).uuidString
                    uuid = u
                    summary = u
                }
            case UInt32(LC_BUILD_VERSION):
                name = "LC_BUILD_VERSION"
                let p = data.le32(cursor + 8)
                platform = Self.platformName(p)
                minOS = Self.version(data.le32(cursor + 12))
                sdk = Self.version(data.le32(cursor + 16))
                summary = "\(platform ?? "") min \(minOS ?? "") sdk \(sdk ?? "")"
            case UInt32(LC_VERSION_MIN_MACOSX):
                name = "LC_VERSION_MIN_MACOSX"
                platform = "macOS"
                minOS = Self.version(data.le32(cursor + 8))
                sdk = Self.version(data.le32(cursor + 12))
                summary = "min \(minOS ?? "") sdk \(sdk ?? "")"
            case LC_MAIN:
                name = "LC_MAIN"
                let off = data.le64(cursor + 8)
                entryPoint = off
                summary = "entry offset \(Fmt.hex(off))"
            case UInt32(LC_CODE_SIGNATURE):
                name = "LC_CODE_SIGNATURE"
                codeSignatureSize = data.le32(cursor + 12)
                summary = "\(Fmt.bytes(UInt64(codeSignatureSize))) at offset \(Fmt.hex(UInt64(data.le32(cursor + 8))))"
            case UInt32(LC_ENCRYPTION_INFO_64), UInt32(LC_ENCRYPTION_INFO):
                name = cmd == UInt32(LC_ENCRYPTION_INFO_64) ? "LC_ENCRYPTION_INFO_64" : "LC_ENCRYPTION_INFO"
                encrypted = data.le32(cursor + 16) != 0
                summary = encrypted ? "Encrypted" : "Not encrypted"
            case UInt32(LC_SOURCE_VERSION):
                name = "LC_SOURCE_VERSION"
                let v = data.le64(cursor + 8)
                let s = "\(v >> 40).\((v >> 30) & 0x3ff).\((v >> 20) & 0x3ff).\((v >> 10) & 0x3ff).\(v & 0x3ff)"
                sourceVersion = s
                summary = s
            case UInt32(LC_LOAD_DYLINKER), UInt32(LC_ID_DYLINKER):
                name = cmd == UInt32(LC_LOAD_DYLINKER) ? "LC_LOAD_DYLINKER" : "LC_ID_DYLINKER"
                let off = Int(data.le32(cursor + 8))
                dylinker = data.cString(cursor + off, max: Int(size) - off)
                summary = dylinker ?? ""
            case UInt32(LC_SYMTAB):
                name = "LC_SYMTAB"
                symtab = (Int(data.le32(cursor + 8)), Int(data.le32(cursor + 12)), Int(data.le32(cursor + 16)), Int(data.le32(cursor + 20)))
                summary = "\(symtab!.nsyms) symbols"
            case UInt32(LC_DYSYMTAB): name = "LC_DYSYMTAB"
            case LC_DYLD_INFO_ONLY: name = "LC_DYLD_INFO_ONLY"
            case UInt32(LC_DYLD_INFO): name = "LC_DYLD_INFO"
            case LC_DYLD_CHAINED_FIXUPS: name = "LC_DYLD_CHAINED_FIXUPS"
            case LC_DYLD_EXPORTS_TRIE: name = "LC_DYLD_EXPORTS_TRIE"
            case UInt32(LC_FUNCTION_STARTS): name = "LC_FUNCTION_STARTS"
            case UInt32(LC_DATA_IN_CODE): name = "LC_DATA_IN_CODE"
            case UInt32(LC_DYLIB_CODE_SIGN_DRS): name = "LC_DYLIB_CODE_SIGN_DRS"
            case UInt32(LC_LINKER_OPTIMIZATION_HINT): name = "LC_LINKER_OPTIMIZATION_HINT"
            case UInt32(LC_SEGMENT_SPLIT_INFO): name = "LC_SEGMENT_SPLIT_INFO"
            case UInt32(LC_UNIXTHREAD): name = "LC_UNIXTHREAD"
            case UInt32(LC_SUB_FRAMEWORK): name = "LC_SUB_FRAMEWORK"
            case UInt32(LC_SUB_CLIENT): name = "LC_SUB_CLIENT"
            case UInt32(LC_NOTE): name = "LC_NOTE"
            case UInt32(LC_LINKER_OPTION): name = "LC_LINKER_OPTION"
            case UInt32(LC_ATOM_INFO): name = "LC_ATOM_INFO"
            case UInt32(LC_FILESET_ENTRY): name = "LC_FILESET_ENTRY"
            default: break
            }
            loadCommands.append(LoadCommand(index: i, name: name, size: size, summary: summary))
            cursor += Int(size)
        }
        if let main = entryPoint {
            entryPoint = textVMAddr &+ main
        }
        if let st = symtab, is64 {
            let symBase = base + st.symoff
            let strBase = base + st.stroff
            var result: [Symbol] = []
            result.reserveCapacity(min(st.nsyms, maxSymbols))
            for i in 0..<min(st.nsyms, maxSymbols) {
                let p = symBase + i * 16
                guard p + 16 <= data.count else { break }
                let strx = Int(data.le32(p))
                let type = data[p + 4]
                let sect = data[p + 5]
                let value = data.le64(p + 8)
                if type & 0xe0 != 0 { continue } // stab debugging entries
                let name = strx > 0 && strBase + strx < data.count ? data.cString(strBase + strx, max: 4096) : ""
                let kindBits = type & 0x0e
                let kind: String
                switch kindBits {
                case 0x0: kind = "Undefined (import)"
                case 0x2: kind = "Absolute"
                case 0xe: kind = "Section"
                case 0xc: kind = "Prebound"
                case 0xa: kind = "Indirect"
                default: kind = "Other"
                }
                result.append(Symbol(index: i, name: name, address: value, kind: kind, isExternal: type & 0x01 != 0, section: sect))
            }
            symbols = result
        }
    }

    static func version(_ v: UInt32) -> String {
        let major = v >> 16
        let minor = (v >> 8) & 0xff
        let patch = v & 0xff
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    static func platformName(_ p: UInt32) -> String {
        switch p {
        case 1: return "macOS"
        case 2: return "iOS"
        case 3: return "tvOS"
        case 4: return "watchOS"
        case 5: return "bridgeOS"
        case 6: return "Mac Catalyst"
        case 7: return "iOS Simulator"
        case 11: return "visionOS"
        case 12: return "visionOS Simulator"
        case 10: return "DriverKit"
        default: return "Platform \(p)"
        }
    }
}

// MARK: - Strings

extension MachOFile {
    /// A run of text found in one of the selected slice's sections.
    public struct ExtractedString: Sendable, Identifiable, Hashable {
        public var id: Int
        public var text: String
        /// "__TEXT,__cstring" and so on.
        public var section: String
        public var address: UInt64
        /// Offset in the file (not the slice).
        public var fileOffset: Int
        public var encoding: Encoding

        public enum Encoding: String, Sendable {
            case utf8 = "UTF-8"
            case ascii = "ASCII"
            case utf16 = "UTF-16"
        }
    }

    public struct StringsResult: Sendable {
        public var strings: [ExtractedString]
        /// Whether `limit` cut the list short.
        public var truncated: Bool
    }

    /// The text in the selected slice's sections, in file order. C-string sections (`__cstring`,
    /// `__objc_methname`, `__oslogstring`…) are split at their NUL terminators and decoded as UTF-8;
    /// `__ustring` holds UTF-16. Other sections are searched for runs of printable ASCII, as
    /// `strings(1)` does. Code, stubs, pointer tables and zero-fill sections are skipped: they hold
    /// no text, only byte patterns that happen to look like it. So is `__LINKEDIT`, whose symbol
    /// names the Symbols page lists.
    public func strings(minLength: Int = 4, limit: Int = 200_000) throws -> StringsResult {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        } catch {
            throw ParseError.unreadable(error.localizedDescription)
        }
        guard slices.indices.contains(selectedSlice) else { return StringsResult(strings: [], truncated: false) }
        let base = slices[selectedSlice].offset
        let minLength = max(1, minLength)
        var out: [ExtractedString] = []
        var truncated = false
        // Sections of a crafted file can overlap, each claiming the same large run of text. The
        // work and the memory are bounded by the file's size, not by what its sections claim.
        var scanned = 0
        var kept = 0
        let scanLimit = 4 * max(data.count, 1)
        let keepLimit = 256 << 20
        let longest = 1 << 20

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            sectionLoop: for segment in segments where segment.name != "__LINKEDIT" {
                for section in segment.sections {
                    let type = section.flags & 0xff
                    let instructions = section.flags & 0x8000_0400 != 0
                    let noText: Set<UInt32> = [0x1, 0x6, 0x7, 0x8, 0x9, 0xa, 0xc, 0x10, 0x12, 0x13, 0x15]
                    guard section.offset > 0, section.size > 0, !instructions, !noText.contains(type) else { continue }
                    let start = base + Int(section.offset)
                    guard start < bytes.count else { continue }
                    let end = start + min(Int(clamping: section.size), bytes.count - start)
                    let name = "\(section.segment),\(section.name)"
                    scanned += end - start
                    guard scanned <= scanLimit else { truncated = true; break sectionLoop }

                    func add(_ text: String, at offset: Int, _ encoding: ExtractedString.Encoding) -> Bool {
                        kept += text.utf8.count
                        guard out.count < limit, kept <= keepLimit else { truncated = true; return false }
                        out.append(ExtractedString(id: out.count, text: text, section: name,
                                                   address: section.address &+ UInt64(offset - start),
                                                   fileOffset: offset, encoding: encoding))
                        return true
                    }

                    if type == 0x2 {
                        // C strings: NUL-terminated UTF-8.
                        var i = start
                        while i < end {
                            var j = i
                            while j < end, bytes[j] != 0 { j += 1 }
                            if j - i >= minLength,
                               let text = String(bytes: UnsafeBufferPointer(rebasing: bytes[i..<min(j, i + longest)]), encoding: .utf8),
                               text.count >= minLength {
                                guard add(text, at: i, .utf8) else { break sectionLoop }
                            }
                            i = j + 1
                        }
                    } else if section.name == "__ustring" {
                        // UTF-16 little-endian, NUL-terminated.
                        var i = start
                        while i + 1 < end {
                            var j = i
                            while j + 1 < end, bytes[j] != 0 || bytes[j + 1] != 0 { j += 2 }
                            if (j - i) / 2 >= minLength,
                               let text = String(bytes: UnsafeBufferPointer(rebasing: bytes[i..<min(j, i + longest)]), encoding: .utf16LittleEndian) {
                                guard add(text, at: i, .utf16) else { break sectionLoop }
                            }
                            i = j + 2
                        }
                    } else {
                        // Anything else: printable ASCII runs.
                        var i = start
                        while i < end {
                            var j = i
                            while j < end, bytes[j] == 0x09 || (0x20...0x7e).contains(bytes[j]) { j += 1 }
                            if j - i >= minLength {
                                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[i..<min(j, i + longest)]), as: UTF8.self)
                                guard add(text, at: i, .ascii) else { break sectionLoop }
                            }
                            i = j + 1
                        }
                    }
                }
            }
        }
        return StringsResult(strings: out, truncated: truncated)
    }
}

private extension Data {
    func le32(_ o: Int) -> UInt32 {
        guard o >= 0, o <= count - 4 else { return 0 }
        return withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }

    func le64(_ o: Int) -> UInt64 {
        guard o >= 0, o <= count - 8 else { return 0 }
        return withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    }

    func be32(_ o: Int) -> UInt32 {
        guard o >= 0, o <= count - 4 else { return 0 }
        return withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }

    func be64(_ o: Int) -> UInt64 {
        guard o >= 0, o <= count - 8 else { return 0 }
        return withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    }

    func cString(_ o: Int, max: Int) -> String {
        guard o >= 0, o < count, max > 0 else { return "" }
        let end = Swift.min(count, o + max)
        var e = o
        withUnsafeBytes { raw in
            while e < end, raw[e] != 0 { e += 1 }
        }
        return String(decoding: self[o..<e], as: UTF8.self)
    }
}
