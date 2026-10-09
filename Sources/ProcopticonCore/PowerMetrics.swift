import Foundation

/// One sample from `powermetrics`: thermal pressure, CPU cluster frequencies and measured power.
public struct PowerMetricsSample: Sendable {
    public struct Cluster: Sendable, Hashable {
        /// "E-Cluster", "P0-Cluster"…
        public var name: String
        /// Average frequency while active over the sample.
        public var frequencyHz: Double
        /// Share of the sample the cluster was active (0…1).
        public var activeRatio: Double
    }

    /// Nominal, Moderate, Heavy, Trapping or Sleeping.
    public var thermalPressure: String?
    public var clusters: [Cluster] = []
    /// Watts.
    public var cpuPower: Double?
    public var gpuPower: Double?
    public var anePower: Double?
    public var combinedPower: Double?
    public var gpuFrequencyMHz: Double?
    public var gpuActiveRatio: Double?

    /// 0 for Nominal up to 4 for Sleeping, for graphs.
    public var thermalPressureLevel: Double? {
        guard let thermalPressure else { return nil }
        return PowerMetrics.pressureLevels.firstIndex(of: thermalPressure).map(Double.init)
    }
}

public enum PowerMetrics {
    public static let tool = "/usr/bin/powermetrics"
    public static let arguments = ["--samplers", "cpu_power,gpu_power,thermal", "-i", "1000", "-f", "plist"]
    public static let pressureLevels = ["Nominal", "Moderate", "Heavy", "Trapping", "Sleeping"]

    public static func parse(_ data: Data) -> PowerMetricsSample? {
        guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
        var s = PowerMetricsSample()
        s.thermalPressure = d["thermal_pressure"] as? String
        if let p = d["processor"] as? [String: Any] {
            for c in p["clusters"] as? [[String: Any]] ?? [] {
                guard let name = c["name"] as? String, let freq = number(c["freq_hz"]) else { continue }
                // The cluster's own idle ratio reads 0 on Apple silicon; its CPUs' are what count.
                let cpuIdle = (c["cpus"] as? [[String: Any]] ?? []).compactMap { number($0["idle_ratio"]) }
                let idle = cpuIdle.isEmpty ? number(c["idle_ratio"]) ?? 0 : cpuIdle.reduce(0, +) / Double(cpuIdle.count)
                s.clusters.append(.init(name: name, frequencyHz: freq, activeRatio: max(0, min(1, 1 - idle))))
            }
            s.cpuPower = number(p["cpu_power"]).map { $0 / 1000 }
            s.gpuPower = number(p["gpu_power"]).map { $0 / 1000 }
            s.anePower = number(p["ane_power"]).map { $0 / 1000 }
            s.combinedPower = number(p["combined_power"]).map { $0 / 1000 }
        }
        if let g = d["gpu"] as? [String: Any] {
            s.gpuFrequencyMHz = number(g["freq_hz"])
            s.gpuActiveRatio = number(g["idle_ratio"]).map { max(0, min(1, 1 - $0)) }
        }
        return s
    }

    /// Reassembles the plist samples powermetrics writes one after another (separated by NULs)
    /// from lines of its output.
    public struct Assembler {
        private var buffer = ""

        public init() {}

        public mutating func feed(_ lines: [String]) -> [PowerMetricsSample] {
            var samples: [PowerMetricsSample] = []
            for raw in lines {
                let line = raw.replacingOccurrences(of: "\0", with: "")
                if line.hasPrefix("<?xml") {
                    buffer = ""
                }
                buffer += line + "\n"
                if line.contains("</plist>") {
                    if let s = PowerMetrics.parse(Data(buffer.utf8)) {
                        samples.append(s)
                    }
                    buffer = ""
                }
            }
            return samples
        }
    }
}
