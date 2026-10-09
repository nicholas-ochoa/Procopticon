import AppKit
import ProcopticonCore
import SwiftUI

/// Runs powermetrics (as root) while something shows its numbers: CPU cluster frequencies, thermal
/// pressure and measured CPU, GPU and Neural Engine power.
@MainActor
final class PowerMetricsMonitor: ObservableObject {
    static let shared = PowerMetricsMonitor()

    @Published private(set) var latest: PowerMetricsSample?
    @Published private(set) var revision = 0
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var error: String?

    /// Megahertz per cluster, oldest first.
    private(set) var clusterFrequency: [String: History] = [:]
    private(set) var clusterNames: [String] = []
    private(set) var cpuPower = History()
    private(set) var gpuPower = History()
    private(set) var anePower = History()
    private(set) var gpuFrequency = History()
    private(set) var pressure = History()

    private var users = 0
    private var stream: ToolStream?
    private var assembler = PowerMetrics.Assembler()

    /// A view that shows the numbers appeared. Starts powermetrics if it can without asking for a
    /// password (or with `prompt`).
    func acquire(prompt: Bool = false) {
        users += 1
        start(prompt: prompt)
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        // Not straight away: switching sections releases one view just before the next acquires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.users == 0 else { return }
            self.stream?.stop()
            self.stream = nil
            self.running = false
        }
    }

    func start(prompt: Bool) {
        guard stream == nil, !starting, users > 0, prompt || Elevation.shared.isElevated else { return }
        starting = true
        error = nil
        assembler = PowerMetrics.Assembler()
        let stream = ToolStream(tool: PowerMetrics.tool, arguments: PowerMetrics.arguments)
        let handler: @MainActor (ToolStream.Event) -> Void = { [weak self] in self?.handle($0) }
        Task {
            if let e = await stream.start(requiresRoot: true, prompt: prompt, interval: 0.5, handler: handler) {
                starting = false
                if e != .cancelled, !e.isPermissionDenied {
                    error = e.message
                }
                return
            }
            self.stream = stream
            starting = false
            running = true
        }
    }

    private func handle(_ event: ToolStream.Event) {
        switch event {
        case .lines(let lines):
            for sample in assembler.feed(lines) {
                record(sample)
            }
        case .dropped:
            break
        case .finished(let status, let errorOutput):
            stream = nil
            running = false
            if status != 0, !errorOutput.isEmpty {
                error = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func record(_ s: PowerMetricsSample) {
        for c in s.clusters {
            if clusterFrequency[c.name] == nil {
                clusterFrequency[c.name] = History()
                clusterNames.append(c.name)
            }
            clusterFrequency[c.name]?.append(c.frequencyHz / 1e6)
        }
        cpuPower.append(s.cpuPower ?? 0)
        gpuPower.append(s.gpuPower ?? 0)
        anePower.append(s.anePower ?? 0)
        gpuFrequency.append(s.gpuFrequencyMHz ?? 0)
        pressure.append(s.thermalPressureLevel ?? 0)
        latest = s
        revision &+= 1
    }

    /// "E 2.03 GHz · P0 3.38 GHz", for one line.
    var frequencySummary: String? {
        guard let latest, !latest.clusters.isEmpty else { return nil }
        return latest.clusters.map { c in
            let name = c.name.replacingOccurrences(of: "-Cluster", with: "")
            return "\(name) \(String(format: "%.2f", c.frequencyHz / 1e9)) GHz"
        }.joined(separator: " · ")
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var explanation: String {
        switch self {
        case .nominal: return "Running normally."
        case .fair: return "Slightly warm; the system may start cooling down (fans)."
        case .serious: return "Hot: performance is being reduced to cool down."
        case .critical: return "Very hot: performance is heavily reduced."
        @unknown default: return ""
        }
    }

    var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
}
