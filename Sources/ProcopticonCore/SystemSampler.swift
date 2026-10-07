import CSysInfo
import Darwin
import Foundation
import IOKit

public struct CPUTicks: Codable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64
    public var total: UInt64 { user &+ system &+ idle &+ nice }
}

public struct VMStats: Codable, Sendable {
    public var pageSize: UInt64
    public var totalBytes: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var speculative: UInt64
    public var compressor: UInt64
    public var compressedUncompressed: UInt64
    public var purgeable: UInt64
    public var external: UInt64
    public var internalPages: UInt64
    public var pageins: UInt64
    public var pageouts: UInt64
    public var faults: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64
    public var swapins: UInt64
    public var swapouts: UInt64
    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var pressureLevel: Int32
    /// Share of memory the system considers available (kern.memorystatus_level), 0...100.
    public var availablePercent: Int32 = 100

    /// Activity-Monitor style breakdown (bytes).
    public var appMemory: UInt64 { (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize }
    public var wiredBytes: UInt64 { wired * pageSize }
    public var compressedBytes: UInt64 { compressor * pageSize }
    public var cachedFiles: UInt64 { (external + purgeable) * pageSize }
    public var freeBytes: UInt64 { (free + speculative) * pageSize }
    public var usedBytes: UInt64 { appMemory + wiredBytes + compressedBytes }

    public var pressureDescription: String {
        switch pressureLevel {
        case 1: return "Normal"
        case 2: return "Warning"
        case 4: return "Critical"
        default: return "Unknown"
        }
    }
}

public struct NetInterfaceStats: Codable, Sendable {
    public var name: String
    public var flags: UInt32
    public var type: UInt8
    public var ibytes: UInt64
    public var obytes: UInt64
    public var ipackets: UInt64
    public var opackets: UInt64
    public var ierrors: UInt64
    public var oerrors: UInt64
    public var baudrate: UInt64

    public var isUp: Bool { flags & UInt32(IFF_UP) != 0 }
    public var isLoopback: Bool { flags & UInt32(IFF_LOOPBACK) != 0 }
}

public struct DiskIOStats: Codable, Sendable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var opsRead: UInt64
    public var opsWritten: UInt64
}

public struct GPUStats: Codable, Sendable {
    public var name: String
    public var utilization: Double        // 0...100
    public var rendererUtilization: Double
    public var tilerUtilization: Double
    public var memoryUsed: UInt64
    public var memoryAllocated: UInt64
    public var coreCount: Int?
}

public struct BatteryStats: Codable, Sendable {
    public var present: Bool
    public var percent: Double
    public var charging: Bool
    public var onAC: Bool
    public var cycleCount: Int
    public var timeRemainingMinutes: Int
    public var designCapacity: Int
    public var maxCapacity: Int
    public var temperatureC: Double
    public var watts: Double
}

public struct SystemSnapshot: Codable, Sendable {
    public var timestamp: Double
    public var cpus: [CPUTicks]
    public var vm: VMStats
    public var disk: DiskIOStats
    public var interfaces: [NetInterfaceStats]
    public var loadAverage: [Double]
    public var bootTime: Double
    public var gpus: [GPUStats]
    public var battery: BatteryStats?
}

public enum SystemSampler {
    public static func sample() -> SystemSnapshot {
        var cpus: [CPUTicks] = []
        var ticks = [si_cpu_ticks](repeating: si_cpu_ticks(), count: 512)
        let n = si_cpu_ticks_per_core(&ticks, Int32(ticks.count))
        if n > 0 {
            cpus = ticks[0..<Int(n)].map { CPUTicks(user: $0.user, system: $0.system, idle: $0.idle, nice: $0.nice) }
        }

        var v = si_vm_stats()
        si_vm_statistics(&v)
        let vm = VMStats(
            pageSize: v.pageSize, totalBytes: v.totalBytes, free: v.freePages, active: v.activePages,
            inactive: v.inactivePages, wired: v.wiredPages, speculative: v.speculativePages,
            compressor: v.compressorPages, compressedUncompressed: v.compressedPages, purgeable: v.purgeablePages,
            external: v.externalPages, internalPages: v.internalPages, pageins: v.pageins, pageouts: v.pageouts,
            faults: v.faults, compressions: v.compressions, decompressions: v.decompressions, swapins: v.swapins,
            swapouts: v.swapouts, swapTotal: v.swapTotal, swapUsed: v.swapUsed, pressureLevel: v.pressureLevel,
            availablePercent: memoryAvailablePercent())

        var d = si_disk_io()
        si_disk_io_totals(&d)
        let disk = DiskIOStats(bytesRead: d.bytesRead, bytesWritten: d.bytesWritten, opsRead: d.opsRead, opsWritten: d.opsWritten)

        var ifs = [si_netif](repeating: si_netif(), count: 128)
        let ni = si_net_interfaces(&ifs, Int32(ifs.count))
        var interfaces: [NetInterfaceStats] = []
        if ni > 0 {
            for i in 0..<Int(ni) {
                let f = ifs[i]
                let name = withUnsafeBytes(of: f.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                interfaces.append(NetInterfaceStats(
                    name: name, flags: f.flags, type: f.type, ibytes: f.ibytes, obytes: f.obytes,
                    ipackets: f.ipackets, opackets: f.opackets, ierrors: f.ierrors, oerrors: f.oerrors, baudrate: f.baudrate))
            }
        }

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        return SystemSnapshot(
            timestamp: Date().timeIntervalSince1970, cpus: cpus, vm: vm, disk: disk, interfaces: interfaces,
            loadAverage: load, bootTime: Double(si_boot_time()), gpus: gpuStats(), battery: batteryStats())
    }

    static func memoryAvailablePercent() -> Int32 {
        var level: Int32 = 100
        var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0)
        return level
    }

    public static func gpuStats() -> [GPUStats] {
        var result: [GPUStats] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            let perf = dict["PerformanceStatistics"] as? [String: Any] ?? [:]
            func num(_ key: String) -> Double { (perf[key] as? NSNumber)?.doubleValue ?? 0 }
            var name = dict["model"] as? String ?? ""
            if name.isEmpty, let data = dict["model"] as? Data {
                name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name.isEmpty {
                name = (dict["IOClass"] as? String) ?? "GPU"
            }
            result.append(GPUStats(
                name: name,
                utilization: num("Device Utilization %"),
                rendererUtilization: num("Renderer Utilization %"),
                tilerUtilization: num("Tiler Utilization %"),
                memoryUsed: UInt64(num("In use system memory")),
                memoryAllocated: UInt64(num("Alloc system memory")),
                coreCount: (dict["gpu-core-count"] as? NSNumber)?.intValue))
        }
        return result
    }

    public static func batteryStats() -> BatteryStats? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        func int(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        let present = (dict["BatteryInstalled"] as? Bool) ?? false
        let current = int("CurrentCapacity")
        let maxCap = int("MaxCapacity")
        let rawMax = int("AppleRawMaxCapacity")
        let percent = maxCap > 0 ? Double(current) / Double(maxCap) * 100 : 0
        let voltage = Double(int("Voltage")) / 1000
        let amperage = Double(Int16(truncatingIfNeeded: int("InstantAmperage"))) / 1000
        return BatteryStats(
            present: present, percent: maxCap <= 100 ? Double(current) : percent,
            charging: (dict["IsCharging"] as? Bool) ?? false,
            onAC: (dict["ExternalConnected"] as? Bool) ?? false,
            cycleCount: int("CycleCount"), timeRemainingMinutes: int("TimeRemaining"),
            designCapacity: int("DesignCapacity"), maxCapacity: rawMax > 0 ? rawMax : maxCap,
            temperatureC: Double(int("Temperature")) / 100, watts: abs(voltage * amperage))
    }
}

/// Static machine description for the System Information window.
public struct MachineInfo: Sendable {
    public var modelIdentifier: String
    public var cpuBrand: String
    public var physicalCores: Int
    public var logicalCores: Int
    public var performanceCores: Int
    public var efficiencyCores: Int
    /// The core type of each logical CPU ("Efficiency", "Performance"), in CPU number order; empty
    /// on Macs with a single core type.
    public var coreTypes: [String]
    public var memoryBytes: UInt64
    public var osVersion: String
    public var kernelVersion: String
    public var hostName: String
    public var pageSize: Int

    public static let current: MachineInfo = {
        func str(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(cString: buf)
        }
        func int(_ name: String) -> Int {
            var v: Int64 = 0
            var size = MemoryLayout<Int64>.size
            if sysctlbyname(name, &v, &size, nil, 0) != 0 {
                var v32: Int32 = 0
                size = MemoryLayout<Int32>.size
                if sysctlbyname(name, &v32, &size, nil, 0) == 0 { return Int(v32) }
                return 0
            }
            return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
        }
        // Logical CPUs are numbered from the least to the most powerful core type, and
        // perflevel0 is the most powerful.
        let levels = int("hw.nperflevels")
        let coreTypes = levels > 1
            ? (0..<levels).reversed().flatMap { level in
                Array(repeating: str("hw.perflevel\(level).name"), count: int("hw.perflevel\(level).logicalcpu"))
            }
            : []
        let pv = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(
            modelIdentifier: str("hw.model"),
            cpuBrand: str("machdep.cpu.brand_string"),
            physicalCores: int("hw.physicalcpu"),
            logicalCores: int("hw.logicalcpu"),
            performanceCores: int("hw.perflevel0.physicalcpu"),
            efficiencyCores: int("hw.perflevel1.physicalcpu"),
            coreTypes: coreTypes,
            memoryBytes: UInt64(int("hw.memsize")),
            osVersion: "macOS \(pv.majorVersion).\(pv.minorVersion).\(pv.patchVersion) (\(str("kern.osversion")))",
            kernelVersion: str("kern.version"),
            hostName: ProcessInfo.processInfo.hostName,
            pageSize: Int(getpagesize()))
    }()
}
