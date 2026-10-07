import CSysInfo
import Darwin
import Foundation

/// Parsed KERN_PROCARGS2 contents.
public struct ProcessArguments: Codable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String]

    public static func read(pid: Int32) -> Result<ProcessArguments, POSIXError> {
        var buffer: UnsafeMutablePointer<CChar>?
        let length = si_proc_args_raw(pid, &buffer)
        guard length > 0, let buffer else {
            return .failure(POSIXError(POSIXErrorCode(rawValue: -length) ?? .EPERM))
        }
        defer { free(buffer) }
        return .success(parse(UnsafeRawBufferPointer(start: buffer, count: Int(length))))
    }

    static func parse(_ raw: UnsafeRawBufferPointer) -> ProcessArguments {
        guard raw.count > 4 else {
            return ProcessArguments(executablePath: "", arguments: [], environment: [])
        }
        let argc = Int(raw.loadUnaligned(as: Int32.self))
        var index = 4
        func readString() -> String? {
            guard index < raw.count else { return nil }
            let start = index
            while index < raw.count, raw[index] != 0 {
                index += 1
            }
            let s = String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<index]), as: UTF8.self)
            return s
        }
        func skipNulls() {
            while index < raw.count, raw[index] == 0 {
                index += 1
            }
        }
        let exec = readString() ?? ""
        skipNulls()
        var args: [String] = []
        while args.count < argc, index < raw.count {
            guard let s = readString() else { break }
            args.append(s)
            index += 1
        }
        var env: [String] = []
        while index < raw.count {
            guard let s = readString(), !s.isEmpty else { break }
            env.append(s)
            index += 1
        }
        // The tail after the environment holds apple[] strings (executable_path=..., etc.) which
        // follow an extra NUL; those are intentionally excluded above.
        return ProcessArguments(executablePath: exec, arguments: args, environment: env)
    }
}

/// Collects process records using libproc + sysctl. Not thread safe; use from one queue.
public final class ProcessSampler {
    private struct StaticInfo {
        var path: String?
        var arguments: [String]?
        var csFlags: UInt32?
        var sandboxed: Bool?
        var responsiblePid: Int32?
        var complete: Bool
    }

    private var cache: [ProcessKey: StaticInfo] = [:]

    public init() {}

    public func sample() -> [ProcessRecord] {
        var list: UnsafeMutablePointer<si_kinfo>?
        let count = si_list_kinfo(&list)
        guard count > 0, let list else {
            return []
        }
        defer { free(list) }

        var records: [ProcessRecord] = []
        records.reserveCapacity(Int(count))
        var seen = Set<ProcessKey>()
        for i in 0..<Int(count) {
            let k = list[i]
            let comm = withUnsafeBytes(of: k.comm) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            var record = ProcessRecord(
                pid: k.pid, ppid: k.ppid, pgid: k.pgid, uid: k.uid, ruid: k.ruid, rgid: k.rgid, svuid: k.svuid,
                status: k.status, flags: k.flags, nice: k.nice, tty: k.tdev,
                startMicros: k.startSec * 1_000_000 + k.startUsec, comm: comm)
            let key = record.key
            seen.insert(key)

            var info = cache[key] ?? StaticInfo(complete: false)
            if !info.complete {
                info = loadStatic(pid: k.pid, existing: info)
                cache[key] = info
            }
            record.path = info.path
            record.arguments = info.arguments
            record.csFlags = info.csFlags
            record.sandboxed = info.sandboxed
            record.responsiblePid = info.responsiblePid

            var stats = si_task_stats()
            if si_task_stats_for_pid(k.pid, &stats) == 0 {
                record.stats = TaskStats(stats)
                if stats.hasBsdInfo != 0 {
                    record.nice = stats.nice
                }
            }
            let fds = si_fd_count(k.pid)
            if fds >= 0, record.stats != nil {
                record.fdCount = fds
            }
            if record.isStopped == false, let flags = csStatus(k.pid) {
                // Code signing flags can change at runtime (e.g. CS_DEBUGGED), refresh each sample.
                record.csFlags = flags
            }
            records.append(record)
        }
        cache = cache.filter { seen.contains($0.key) }
        return records
    }

    private func csStatus(_ pid: Int32) -> UInt32? {
        var flags: UInt32 = 0
        return si_cs_status(pid, &flags) == 0 ? flags : nil
    }

    private func loadStatic(pid: Int32, existing: StaticInfo) -> StaticInfo {
        var info = existing
        if info.path == nil {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                info.path = String(cString: buf)
            }
        }
        if info.arguments == nil, pid != 0 {
            if case .success(let args) = ProcessArguments.read(pid: pid) {
                info.arguments = args.arguments
                if info.path == nil, !args.executablePath.isEmpty {
                    info.path = args.executablePath
                }
            }
        }
        if info.sandboxed == nil {
            let s = si_is_sandboxed(pid)
            info.sandboxed = s < 0 ? nil : s == 1
        }
        if info.responsiblePid == nil {
            let r = si_responsible_pid(pid)
            info.responsiblePid = r > 0 ? r : nil
        }
        info.csFlags = csStatus(pid)
        // Inaccessible arguments (other users' processes without elevation) stay unavailable for
        // this sampler's lifetime; elevation swaps in a different sampler.
        info.complete = true
        return info
    }
}
