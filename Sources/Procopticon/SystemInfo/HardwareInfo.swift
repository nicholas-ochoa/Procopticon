import Darwin
import Foundation
import IOKit
import Metal

/// What the hardware is, beside the live figures in System Information: the Mac's name, its core
/// types and caches, and what each GPU supports. Read once; none of it changes while the Mac runs.
/// Network addresses, which do change, are read by `InterfaceAddresses`.
struct HardwareInfo: Sendable {
    /// One perflevel: the Performance or Efficiency cores.
    struct CoreType: Sendable, Identifiable {
        var id: Int { level }
        var level: Int
        var name: String
        var physicalCores: Int
        var logicalCores: Int
        var l1InstructionCache: Int
        var l1DataCache: Int
        var l2Cache: Int
        /// How many cores share each L2 cache.
        var coresPerL2: Int
    }

    struct GPU: Sendable, Identifiable {
        var id: UInt64 { registryID }
        var registryID: UInt64
        var name: String
        var location: String
        var unifiedMemory: Bool
        var recommendedWorkingSet: UInt64
        var maxBufferLength: Int
        var maxThreadsPerThreadgroup: Int
        var maxThreadgroupMemory: Int
        /// "Apple 9", "Metal 4"…
        var families: [String]
        var raytracing: Bool
        var lowPower: Bool
        var headless: Bool
        var removable: Bool
    }

    /// "MacBook Pro (16-inch, Nov 2023)"; nil on Macs whose device tree doesn't say.
    var productName: String?
    var architecture: String
    var coreTypes: [CoreType]
    /// Caches for Macs with one core type, where there are no perflevels.
    var l1InstructionCache: Int
    var l1DataCache: Int
    var l2Cache: Int
    var l3Cache: Int
    var cacheLineSize: Int
    var usableMemory: UInt64
    var gpus: [GPU]

    static let current = HardwareInfo.read()

    private static func read() -> HardwareInfo {
        let levels = sysctlInt("hw.nperflevels")
        let coreTypes: [CoreType] = levels > 1 ? (0..<levels).map { level in
            let prefix = "hw.perflevel\(level)."
            return CoreType(
                level: level, name: sysctlString(prefix + "name"),
                physicalCores: sysctlInt(prefix + "physicalcpu"), logicalCores: sysctlInt(prefix + "logicalcpu"),
                l1InstructionCache: sysctlInt(prefix + "l1icachesize"), l1DataCache: sysctlInt(prefix + "l1dcachesize"),
                l2Cache: sysctlInt(prefix + "l2cachesize"), coresPerL2: sysctlInt(prefix + "cpusperl2"))
        } : []
        return HardwareInfo(
            productName: productName(),
            architecture: sysctlString("hw.machine"),
            coreTypes: coreTypes,
            l1InstructionCache: sysctlInt("hw.l1icachesize"),
            l1DataCache: sysctlInt("hw.l1dcachesize"),
            l2Cache: sysctlInt("hw.l2cachesize"),
            l3Cache: sysctlInt("hw.l3cachesize"),
            cacheLineSize: sysctlInt("hw.cachelinesize"),
            usableMemory: UInt64(max(0, sysctlInt("hw.memsize_usable"))),
            gpus: MTLCopyAllDevices().map(gpu))
    }

    private static func gpu(_ device: MTLDevice) -> GPU {
        var families: [String] = []
        // The newest Apple family the GPU supports implies the older ones.
        if let apple = (1...11).reversed().first(where: { MTLGPUFamily(rawValue: 1000 + $0).map(device.supportsFamily) ?? false }) {
            families.append("Apple \(apple)")
        }
        if device.supportsFamily(.metal4) {
            families.append("Metal 4")
        } else if device.supportsFamily(.metal3) {
            families.append("Metal 3")
        }
        let location: String
        switch device.location {
        case .builtIn: location = "Built-in"
        case .slot: location = "Expansion slot"
        case .external: location = "External"
        default: location = ""
        }
        return GPU(
            registryID: device.registryID, name: device.name, location: location,
            unifiedMemory: device.hasUnifiedMemory, recommendedWorkingSet: device.recommendedMaxWorkingSetSize,
            maxBufferLength: device.maxBufferLength, maxThreadsPerThreadgroup: device.maxThreadsPerThreadgroup.width,
            maxThreadgroupMemory: device.maxThreadgroupMemoryLength, families: families,
            raytracing: device.supportsRaytracing, lowPower: device.isLowPower, headless: device.isHeadless,
            removable: device.isRemovable)
    }

    /// The marketing name Apple Silicon Macs keep in the device tree's `product` node.
    private static func productName() -> String? {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != 0 else { return nil }
        defer { IOObjectRelease(product) }
        guard let data = IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// The addresses and link details of a network interface, from `getifaddrs`.
struct InterfaceAddresses: Sendable {
    var name: String
    var hardwareAddress: String?
    var ipv4: [String] = []
    var ipv6: [String] = []
    var mtu: Int?
    /// Bits per second, when the driver reports it.
    var linkSpeed: UInt64?

    /// Every interface's addresses, by interface name.
    static func read() -> [String: InterfaceAddresses] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        var result: [String: InterfaceAddresses] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            var info = result[name] ?? InterfaceAddresses(name: name)
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let length = Int(dl.pointee.sdl_alen)
                    let offset = Int(dl.pointee.sdl_nlen)
                    // The address follows the name in sdl_data, which can run past the declared
                    // 12 bytes (into sdl_len) for long names such as bridge100.
                    guard length == 6, let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data),
                          dataOffset + offset + length <= Int(dl.pointee.sdl_len) else { return }
                    let start = UnsafeRawPointer(dl).advanced(by: dataOffset + offset).assumingMemoryBound(to: UInt8.self)
                    info.hardwareAddress = UnsafeBufferPointer(start: start, count: length)
                        .map { String(format: "%02x", $0) }.joined(separator: ":")
                }
                if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    info.mtu = Int(data.ifi_mtu)
                    info.linkSpeed = data.ifi_baudrate > 0 ? UInt64(data.ifi_baudrate) : nil
                }
            case AF_INET, AF_INET6:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(addr.pointee.sa_family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: host)
                    if addr.pointee.sa_family == AF_INET { info.ipv4.append(text) } else { info.ipv6.append(text) }
                }
            default:
                break
            }
            result[name] = info
        }
        return result
    }
}

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf)
}

private func sysctlInt(_ name: String) -> Int {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return 0 }
    return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
}
