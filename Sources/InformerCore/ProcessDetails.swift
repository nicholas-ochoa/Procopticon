import CSysInfo
import Darwin
import Foundation

public struct FileDescriptorInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: Int32 { fd }
    public var fd: Int32
    public var type: String
    public var name: String
    public var openFlags: UInt32
    public var offset: Int64
    public var size: Int64
    public var vnodeType: Int32
    public var socket: SocketEndpoint?

    public var accessDescription: String {
        // fi_openflags holds kernel FREAD (1) / FWRITE (2) bits rather than O_ACCMODE values.
        var parts: [String] = []
        switch openFlags & 3 {
        case 1: parts.append("Read")
        case 2: parts.append("Write")
        case 3: parts.append("Read/Write")
        default: break
        }
        if openFlags & UInt32(O_APPEND) != 0 { parts.append("Append") }
        if openFlags & UInt32(O_NONBLOCK) != 0 { parts.append("Non-blocking") }
        if openFlags & UInt32(O_CLOEXEC) != 0 { parts.append("Close-on-exec") }
        return parts.joined(separator: ", ")
    }
}

public struct SocketEndpoint: Codable, Sendable, Hashable {
    public var family: Int32
    public var sockType: Int32
    public var proto: Int32
    public var tcpState: Int32
    public var localAddress: String
    public var localPort: UInt16
    public var remoteAddress: String
    public var remotePort: UInt16
    public var sendQueue: UInt32
    public var recvQueue: UInt32
    public var unixPath: String

    public var protocolName: String {
        switch family {
        case AF_UNIX: return "Unix"
        case AF_INET, AF_INET6:
            let v6 = family == AF_INET6
            switch proto {
            case IPPROTO_TCP: return v6 ? "TCP6" : "TCP"
            case IPPROTO_UDP: return v6 ? "UDP6" : "UDP"
            case IPPROTO_ICMP, IPPROTO_ICMPV6: return v6 ? "ICMP6" : "ICMP"
            default: return v6 ? "IPv6" : "IPv4"
            }
        case AF_SYSTEM: return "System"
        case AF_ROUTE: return "Route"
        case AF_NDRV: return "NDRV"
        default: return "Family \(family)"
        }
    }

    public var stateName: String {
        guard proto == IPPROTO_TCP, tcpState >= 0 else {
            return proto == IPPROTO_UDP ? "" : ""
        }
        let names = ["Closed", "Listen", "SYN Sent", "SYN Received", "Established", "Close Wait",
                     "FIN Wait 1", "Closing", "Last ACK", "FIN Wait 2", "Time Wait"]
        return Int(tcpState) < names.count ? names[Int(tcpState)] : "State \(tcpState)"
    }

    public var isInternet: Bool { family == AF_INET || family == AF_INET6 }
    public var isListening: Bool { proto == IPPROTO_TCP && tcpState == 1 }

    public var summary: String {
        if family == AF_UNIX {
            return unixPath.isEmpty ? "Unix socket" : unixPath
        }
        if isInternet {
            let local = "\(Self.bracket(localAddress)):\(localPort)"
            if remotePort == 0, remoteAddress == "*" || remoteAddress.isEmpty {
                return "\(protocolName) \(local)\(isListening ? " (listening)" : "")"
            }
            return "\(protocolName) \(local) → \(Self.bracket(remoteAddress)):\(remotePort) \(stateName)"
        }
        return protocolName
    }

    static func bracket(_ addr: String) -> String {
        addr.contains(":") ? "[\(addr)]" : addr
    }
}

public struct ThreadInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: UInt64 { threadId }
    public var threadId: UInt64
    public var name: String
    public var userTimeNs: UInt64
    public var systemTimeNs: UInt64
    public var cpuUsage: Double   // percent of one core
    public var policy: Int32
    public var runState: Int32
    public var flags: Int32
    public var sleepTime: Int32
    public var currentPriority: Int32
    public var basePriority: Int32
    public var maxPriority: Int32

    public var stateName: String {
        switch runState {
        case 1: return "Running"
        case 2: return "Stopped"
        case 3: return "Waiting"
        case 4: return "Uninterruptible"
        case 5: return "Halted"
        default: return "Unknown"
        }
    }

    public var policyName: String {
        switch policy {
        case 1: return "Timeshare"
        case 2: return "Round robin"
        case 4: return "FIFO"
        default: return "\(policy)"
        }
    }

    public var flagsDescription: String {
        var parts: [String] = []
        if flags & 0x1 != 0 { parts.append("Swapped") }
        if flags & 0x2 != 0 { parts.append("Idle") }
        if flags & 0x4 != 0 { parts.append("Global forced idle") }
        return parts.joined(separator: ", ")
    }
}

public struct MemoryRegion: Codable, Sendable, Identifiable, Hashable {
    public var id: UInt64 { address }
    public var address: UInt64
    public var size: UInt64
    public var offset: UInt64
    public var protection: UInt32
    public var maxProtection: UInt32
    public var userTag: UInt32
    public var shareMode: UInt32
    public var residentBytes: UInt64
    public var swappedBytes: UInt64
    public var dirtyBytes: UInt64
    public var privateResidentBytes: UInt64
    public var sharedResidentBytes: UInt64
    public var isSubmap: Bool
    public var path: String

    public static func protectionString(_ p: UInt32) -> String {
        (p & 1 != 0 ? "r" : "-") + (p & 2 != 0 ? "w" : "-") + (p & 4 != 0 ? "x" : "-")
    }

    public var protectionDescription: String {
        Self.protectionString(protection) + "/" + Self.protectionString(maxProtection)
    }

    public var shareModeName: String {
        switch shareMode {
        case 1: return "COW"
        case 2: return "Private"
        case 3: return "Empty"
        case 4: return "Shared"
        case 5: return "True shared"
        case 6: return "Private aliased"
        case 7: return "Shared aliased"
        case 8: return "Large page"
        default: return ""
        }
    }

    public var typeName: String {
        if isSubmap {
            return "Submap"
        }
        if let name = Self.tagNames[userTag] {
            return name
        }
        if !path.isEmpty {
            return protection & 4 != 0 ? "Image (code)" : "Mapped file"
        }
        return userTag == 0 ? "Private" : "Tag \(userTag)"
    }

    /// VM_MEMORY_* tags from <mach/vm_statistics.h>.
    static let tagNames: [UInt32: String] = {
        var t: [UInt32: String] = [
            1: "MALLOC", 2: "MALLOC_SMALL", 3: "MALLOC_LARGE", 4: "MALLOC_HUGE", 5: "SBRK", 6: "REALLOC",
            7: "MALLOC_TINY", 8: "MALLOC_LARGE_REUSABLE", 9: "MALLOC_LARGE_REUSED", 10: "Analysis tool",
            11: "MALLOC_NANO", 12: "MALLOC_MEDIUM", 13: "MALLOC_PROB_GUARD", 20: "Mach message", 21: "IOKit",
            22: "VM reclaim", 30: "Stack", 31: "Guard", 32: "Shared pmap", 33: "dylib", 34: "ObjC dispatchers",
            35: "Unshared pmap", 36: "libchannel", 40: "AppKit", 41: "Foundation", 42: "CoreGraphics",
            43: "CoreServices", 44: "Java", 45: "CoreData", 46: "CoreData object IDs", 50: "ATS",
            51: "CoreAnimation", 52: "CG image", 53: "TCMalloc", 54: "CG raster data", 55: "CG shared images",
            56: "CG framebuffers", 57: "CG backing stores", 58: "CG XAlloc", 60: "dyld", 61: "dyld malloc",
            62: "SQLite", 63: "JavaScriptCore", 64: "JIT executable allocator", 65: "JIT register file",
            66: "GLSL", 67: "OpenCL", 68: "CoreImage", 69: "WebCore purgeable buffers", 70: "Image I/O",
            71: "CoreProfile", 72: "Assets", 73: "OS alloc once", 74: "libdispatch", 75: "Accelerate",
            76: "CoreUI", 77: "CoreUI file", 78: "Genealogy", 79: "RawCamera", 80: "Corpse info", 81: "ASL",
            82: "Swift runtime", 83: "Swift metadata", 84: "DHMM", 85: "DFR", 86: "SceneKit", 87: "Skywalk",
            88: "IOSurface", 89: "libnetwork", 90: "Audio", 91: "Video bitstream", 92: "CoreMedia XPC",
            93: "CoreMedia RPC", 94: "CoreMedia memory pool", 95: "CoreMedia read cache", 96: "CoreMedia crabs",
            97: "QuickLook thumbnails", 98: "Accounts", 99: "Sanitizer", 100: "IOAccelerator",
            101: "CoreMedia regwarp", 102: "EAR decoder", 103: "CoreUI cached image data", 104: "ColorSync",
            105: "Backtrace info", 106: "CoreMedia HLS", 107: "Compositor services", 108: "Debug", 109: "Neural",
            230: "Rosetta", 231: "Rosetta thread context", 232: "Rosetta indirect branch map",
            233: "Rosetta return stack", 234: "Rosetta executable heap", 235: "Rosetta user LDT",
            236: "Rosetta arena", 239: "Rosetta 10",
        ]
        for i in 240...255 {
            t[UInt32(i)] = "Application specific \(i - 239)"
        }
        return t
    }()
}

/// A loaded Mach-O image within a process.
public struct ModuleInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String { "\(baseAddress)-\(path)" }
    public var path: String
    public var baseAddress: UInt64
    public var size: UInt64
    public var name: String { (path as NSString).lastPathComponent }
}

public struct NetworkConnection: Codable, Sendable, Identifiable, Hashable {
    public var id: String { "\(pid)-\(fd)-\(endpoint.localPort)-\(endpoint.remoteAddress)-\(endpoint.remotePort)" }
    public var pid: Int32
    public var processName: String
    public var fd: Int32
    public var endpoint: SocketEndpoint
}

/// Result row of a "find open files or libraries" search.
public struct OpenFileMatch: Codable, Sendable, Identifiable, Hashable {
    public var id: String { "\(pid)-\(fd ?? -1)-\(type)-\(name)" }
    public var pid: Int32
    public var processName: String
    public var type: String
    public var fd: Int32?
    public var name: String
}

public enum ProcessDetails {
    /// Searches open file descriptors (and optionally mapped images) of every accessible process.
    public static func searchOpenFiles(query: String, includeLibraries: Bool, regex: Bool = false) -> [OpenFileMatch] {
        let matcher = SearchMatcher(query, regex: regex)
        guard matcher.isValid, !matcher.isEmpty else { return [] }
        var results: [OpenFileMatch] = []
        for (pid, name) in ProcessSampler.lightweightList() {
            if case .success(let fds) = fileDescriptors(pid: pid) {
                for f in fds where matcher.matches(f.name) {
                    results.append(OpenFileMatch(pid: pid, processName: name, type: f.type, fd: f.fd, name: f.name))
                }
            }
            if includeLibraries, case .success(let regions) = regions(pid: pid) {
                var seen = Set<String>()
                for r in regions where !r.path.isEmpty && !seen.contains(r.path) {
                    seen.insert(r.path)
                    if matcher.matches(r.path) {
                        results.append(OpenFileMatch(pid: pid, processName: name, type: r.protection & 4 != 0 ? "Image" : "Mapped file", fd: nil, name: r.path))
                    }
                }
            }
        }
        return results
    }

    public static func fileDescriptors(pid: Int32, socketsOnly: Bool = false) -> Result<[FileDescriptorInfo], POSIXError> {
        var capacity = 1024
        while true {
            var buffer = [si_fd_info](repeating: si_fd_info(), count: capacity)
            let n = si_pid_fds(pid, &buffer, Int32(capacity), socketsOnly ? 1 : 0)
            if n < 0 {
                return .failure(POSIXError(POSIXErrorCode(rawValue: -n) ?? .EPERM))
            }
            if Int(n) == capacity, capacity < 65536 {
                capacity *= 4
                continue
            }
            return .success(buffer[0..<Int(n)].map(convert))
        }
    }

    static func convert(_ f: si_fd_info) -> FileDescriptorInfo {
        let path = withUnsafeBytes(of: f.path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var type: String
        var socket: SocketEndpoint?
        switch Int32(f.fdType) {
        case PROX_FDTYPE_VNODE:
            switch Int32(f.vnodeType) {
            case 1: type = "File"
            case 2: type = "Directory"
            case 3: type = "Block device"
            case 4: type = "Character device"
            case 5: type = "Symlink"
            case 6: type = "Socket file"
            case 7: type = "FIFO"
            default: type = "Vnode"
            }
        case PROX_FDTYPE_SOCKET:
            let ep = endpoint(f)
            socket = ep
            type = ep.family == AF_UNIX ? "Unix socket" : (ep.isInternet ? "Socket (\(ep.protocolName))" : "Socket (\(ep.protocolName))")
        case PROX_FDTYPE_PSHM: type = "Shared memory"
        case PROX_FDTYPE_PSEM: type = "Semaphore"
        case PROX_FDTYPE_KQUEUE: type = "Kqueue"
        case PROX_FDTYPE_PIPE: type = "Pipe"
        case PROX_FDTYPE_FSEVENTS: type = "FSEvents"
        case PROX_FDTYPE_NETPOLICY: type = "Net policy"
        case PROX_FDTYPE_CHANNEL: type = "Channel"
        case PROX_FDTYPE_NEXUS: type = "Nexus"
        default: type = "Unknown (\(f.fdType))"
        }
        let name = socket.map { $0.summary } ?? path
        return FileDescriptorInfo(
            fd: f.fd, type: type, name: name, openFlags: f.openFlags, offset: f.offset, size: f.vnodeSize,
            vnodeType: f.vnodeType, socket: socket)
    }

    static func endpoint(_ f: si_fd_info) -> SocketEndpoint {
        func addr(_ tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> String {
            var t = tuple
            return withUnsafeBytes(of: &t) { raw -> String in
                if f.isIPv6 != 0 {
                    if raw.allSatisfy({ $0 == 0 }) { return "*" }
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, raw.baseAddress, &buf, socklen_t(buf.count))
                    let s = String(cString: buf)
                    return s.hasPrefix("::ffff:") ? String(s.dropFirst(7)) : s
                }
                if raw.prefix(4).allSatisfy({ $0 == 0 }) { return "*" }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, raw.baseAddress, &buf, socklen_t(buf.count))
                return String(cString: buf)
            }
        }
        let path = withUnsafeBytes(of: f.path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return SocketEndpoint(
            family: f.family, sockType: f.sockType, proto: f.protocol, tcpState: f.tcpState,
            localAddress: addr(f.localAddr), localPort: f.localPort,
            remoteAddress: addr(f.remoteAddr), remotePort: f.remotePort,
            sendQueue: f.sendQueue, recvQueue: f.recvQueue, unixPath: f.family == AF_UNIX ? path : "")
    }

    public static func threads(pid: Int32) -> Result<[ThreadInfo], POSIXError> {
        var capacity = 512
        while true {
            var buffer = [si_thread_info](repeating: si_thread_info(), count: capacity)
            let n = si_pid_threads(pid, &buffer, Int32(capacity))
            if n < 0 {
                return .failure(POSIXError(POSIXErrorCode(rawValue: -n) ?? .EPERM))
            }
            if Int(n) == capacity, capacity < 16384 {
                capacity *= 4
                continue
            }
            return .success(buffer[0..<Int(n)].map { t in
                let name = withUnsafeBytes(of: t.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return ThreadInfo(
                    threadId: t.threadId, name: name, userTimeNs: t.userTimeNs, systemTimeNs: t.systemTimeNs,
                    cpuUsage: Double(t.cpuUsage) / 10.0, policy: t.policy, runState: t.runState, flags: t.flags,
                    sleepTime: t.sleepTime, currentPriority: t.currentPriority, basePriority: t.priority,
                    maxPriority: t.maxPriority)
            })
        }
    }

    public static func regions(pid: Int32) -> Result<[MemoryRegion], POSIXError> {
        let capacity = 65536
        let buffer = UnsafeMutablePointer<si_region_info>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let n = si_pid_regions(pid, buffer, Int32(capacity))
        if n < 0 {
            return .failure(POSIXError(POSIXErrorCode(rawValue: -n) ?? .EPERM))
        }
        if n == 0 {
            return .failure(POSIXError(.EPERM))
        }
        let page = UInt64(getpagesize())
        var result: [MemoryRegion] = []
        result.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            let r = buffer[i]
            let path = withUnsafeBytes(of: r.path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            result.append(MemoryRegion(
                address: r.address, size: r.size, offset: r.offset, protection: r.protection,
                maxProtection: r.maxProtection, userTag: r.userTag, shareMode: r.shareMode,
                residentBytes: UInt64(r.pagesResident) * page, swappedBytes: UInt64(r.pagesSwappedOut) * page,
                dirtyBytes: UInt64(r.pagesDirtied) * page, privateResidentBytes: UInt64(r.privatePagesResident) * page,
                sharedResidentBytes: UInt64(r.sharedPagesResident) * page, isSubmap: r.isSubmap != 0, path: path))
        }
        return .success(result)
    }

    /// Images mapped from files (executable segments). Libraries inside the dyld shared cache are
    /// reported by `vmmapModules` instead.
    public static func modulesFromRegions(_ regions: [MemoryRegion]) -> [ModuleInfo] {
        var byPath: [String: ModuleInfo] = [:]
        var order: [String] = []
        for r in regions where !r.path.isEmpty {
            if var m = byPath[r.path] {
                let end = max(m.baseAddress + m.size, r.address + r.size)
                m.baseAddress = min(m.baseAddress, r.address)
                m.size = end - m.baseAddress
                byPath[r.path] = m
            } else if r.protection & 4 != 0 || r.offset == 0 {
                byPath[r.path] = ModuleInfo(path: r.path, baseAddress: r.address, size: r.size)
                order.append(r.path)
            }
        }
        return order.compactMap { byPath[$0] }.filter { m in
            // Only keep Mach-O files.
            isMachO(path: m.path)
        }
    }

    static func isMachO(path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xfeedfacf, 0xfeedface, 0xcafebabe, 0xbebafeca, 0xcffaedfe, 0xcefaedfe].contains(magic)
    }

    /// Parses `vmmap -interleaved -wide` output into image list.
    public static func parseVmmapModules(_ text: String) -> [ModuleInfo] {
        var modules: [String: ModuleInfo] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("__TEXT") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let range = parts[1].split(separator: "-")
            guard range.count == 2, let start = UInt64(range[0], radix: 16), let end = UInt64(range[1], radix: 16) else { continue }
            guard let slash = line.range(of: " /") else { continue }
            let path = String(line[line.index(after: slash.lowerBound)...]).trimmingCharacters(in: .whitespaces)
            if modules[path] == nil {
                modules[path] = ModuleInfo(path: path, baseAddress: start, size: end - start)
                order.append(path)
            }
        }
        return order.compactMap { modules[$0] }
    }

    public static func connections(pids: [(Int32, String)]) -> [NetworkConnection] {
        var result: [NetworkConnection] = []
        for (pid, name) in pids {
            guard case .success(let fds) = fileDescriptors(pid: pid, socketsOnly: true) else { continue }
            for fd in fds {
                guard let ep = fd.socket, ep.isInternet else { continue }
                result.append(NetworkConnection(pid: pid, processName: name, fd: fd.fd, endpoint: ep))
            }
        }
        return result
    }

    public static func allConnections() -> [NetworkConnection] {
        let records = ProcessSampler.lightweightList()
        return connections(pids: records)
    }
}

extension ProcessSampler {
    /// pid + name for every process (cheap).
    public static func lightweightList() -> [(Int32, String)] {
        var list: UnsafeMutablePointer<si_kinfo>?
        let count = si_list_kinfo(&list)
        guard count > 0, let list else { return [] }
        defer { free(list) }
        var out: [(Int32, String)] = []
        for i in 0..<Int(count) {
            let k = list[i]
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            var name: String
            if proc_pidpath(k.pid, &buf, UInt32(buf.count)) > 0 {
                name = (String(cString: buf) as NSString).lastPathComponent
            } else {
                name = withUnsafeBytes(of: k.comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            out.append((k.pid, name))
        }
        return out
    }
}
