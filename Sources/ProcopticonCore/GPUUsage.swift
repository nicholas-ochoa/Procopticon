import Foundation
import IOKit

/// GPU time per process, read from the connections processes open to the GPU (the user clients of
/// each IOAccelerator). Each connection names the process that created it and, on Apple silicon,
/// reports the GPU time its work has used. Reading them needs no privileges.
public enum GPUUsage {
    /// GPU time in nanoseconds by pid, summed over each process's open GPU connections. A
    /// connection's time leaves the sum when the process closes it.
    public static func sample() -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String, let pid = pid(fromCreator: creator),
                      let usage = property(client, "AppUsage") as? [[String: Any]] else {
                    continue
                }
                result[pid, default: 0] &+= gpuTime(appUsage: usage)
            }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// "pid 416, WindowServer" → 416.
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else {
            return nil
        }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }

    /// Total of a connection's "AppUsage" entries (one per command queue API, e.g. Metal).
    static func gpuTime(appUsage: [[String: Any]]) -> UInt64 {
        appUsage.reduce(0) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
    }
}
