import Darwin
import Foundation

/// Runs memory-region enumeration of other processes in a disposable child process.
///
/// On recent macOS releases the kernel can answer `proc_pidinfo(PROC_PIDREGIONPATHINFO)` for some
/// targets with an `EXC_GUARD` (rejected syscall) that terminates the *caller*. Scanning in a child
/// keeps that from ever taking down the app or the privileged helper: if the child dies, the target
/// it was scanning is reported as unreadable and the scan resumes with the remaining processes.
public enum IsolatedScanner {
    /// Executable that understands `--scan-regions` (the bundled `informer-helper`). When nil or
    /// missing, scans run in-process.
    nonisolated(unsafe) public static var executablePath: String?

    private static let startMarker = "#start "

    /// Child-process entry point: reads PIDs (one per line) from stdin and writes one JSON line per PID.
    public static func runChild() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let pids = String(decoding: input, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        let encoder = JSONEncoder()
        for pid in pids {
            // Announce first so the parent knows which target was in flight if we get killed.
            FileHandle.standardOutput.write(Data("\(startMarker)\(pid)\n".utf8))
            let line: ScanLine
            switch ProcessDetails.regions(pid: pid) {
            case .success(let r): line = ScanLine(pid: pid, regions: r, errno: nil)
            case .failure(let e): line = ScanLine(pid: pid, regions: nil, errno: e.code.rawValue)
            }
            if var data = try? encoder.encode(line) {
                data.append(0x0a)
                FileHandle.standardOutput.write(data)
            }
        }
        exit(0)
    }

    struct ScanLine: Codable {
        var pid: Int32
        var regions: [MemoryRegion]?
        var errno: Int32?
    }

    public static func regions(pid: Int32) -> Result<[MemoryRegion], POSIXError> {
        regions(pids: [pid])[pid] ?? .failure(POSIXError(.EPERM))
    }

    /// Scans many processes. Results for targets that killed the scanner are `.EFAULT`.
    public static func regions(pids: [Int32]) -> [Int32: Result<[MemoryRegion], POSIXError>] {
        var results: [Int32: Result<[MemoryRegion], POSIXError>] = [:]
        // Our own process is always safe to scan directly.
        let own = getpid()
        var remaining = pids.filter { $0 != own }
        if pids.contains(own) {
            results[own] = ProcessDetails.regions(pid: own)
        }
        guard let exe = executablePath, FileManager.default.isExecutableFile(atPath: exe) else {
            for pid in remaining { results[pid] = ProcessDetails.regions(pid: pid) }
            return results
        }
        let decoder = JSONDecoder()
        var attempts = 0
        while !remaining.isEmpty, attempts < 64 {
            attempts += 1
            let (output, crashed) = runScanner(exe, pids: remaining)
            var inFlight: Int32?
            for line in output.split(separator: "\n") {
                if line.hasPrefix(startMarker) {
                    inFlight = Int32(line.dropFirst(startMarker.count))
                    continue
                }
                guard let scan = try? decoder.decode(ScanLine.self, from: Data(line.utf8)) else { continue }
                if let r = scan.regions {
                    results[scan.pid] = .success(r)
                } else {
                    results[scan.pid] = .failure(POSIXError(POSIXErrorCode(rawValue: scan.errno ?? EPERM) ?? .EPERM))
                }
                inFlight = nil
            }
            guard crashed else { break }
            if let victim = inFlight {
                results[victim] = .failure(POSIXError(.EFAULT))
            }
            remaining = remaining.filter { results[$0] == nil }
        }
        for pid in remaining where results[pid] == nil {
            results[pid] = .failure(POSIXError(.EFAULT))
        }
        return results
    }

    private static func runScanner(_ exe: String, pids: [Int32]) -> (String, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["--scan-regions"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ("", false)
        }
        var data = Data()
        let reader = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()
        group.enter()
        reader.async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        stdin.fileHandleForWriting.write(Data(pids.map { "\($0)" }.joined(separator: "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        group.wait()
        process.waitUntilExit()
        let crashed = process.terminationReason == .uncaughtSignal
        return (String(decoding: data, as: UTF8.self), crashed)
    }
}
