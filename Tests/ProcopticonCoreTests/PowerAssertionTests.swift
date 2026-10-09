import XCTest
@testable import ProcopticonCore

final class PowerAssertionTests: XCTestCase {
    func testLegacyTypeAndTimeout() {
        let a = PowerAssertions.parse([
            "AssertType": "NoIdleSleepAssertion", "AssertionTrueType": "PreventUserIdleSystemSleep",
            "AssertName": "Electron", "AssertLevel": 255, "AssertPID": 63930, "AssertionId": 35362,
            "TimeoutSeconds": 0, "AssertStartWhen": Date(timeIntervalSince1970: 100),
        ], owner: 63930)
        XCTAssertEqual(a.type, "PreventUserIdleSystemSleep")
        XCTAssertEqual(a.requestedType, "NoIdleSleepAssertion")
        XCTAssertNil(a.timeout, "a zero timeout means none")
        XCTAssertEqual(a.sleepPrevention, .system)
        XCTAssertEqual(a.started, Date(timeIntervalSince1970: 100))
    }

    func testStrongestPreventionWins() {
        let system = PowerAssertions.parse(["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255], owner: 1)
        let display = PowerAssertions.parse(["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255, "TimeoutSeconds": 300,
                                             "AssertTimeoutTimeLeft": 120], owner: 1)
        let off = PowerAssertions.parse(["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 0], owner: 1)
        let active = PowerAssertions.parse(["AssertType": "UserIsActive", "AssertLevel": 255], owner: 1)
        XCTAssertEqual(display.timeLeft, 120)
        XCTAssertEqual([system, display].sleepPrevention, .display)
        XCTAssertEqual([system, off].sleepPrevention, .system)
        XCTAssertNil([active, off].sleepPrevention)
    }

    func testOnBehalfOfAnotherProcess() {
        let a = PowerAssertions.parse(["AssertType": "PreventUserIdleSystemSleep", "AssertPID": 300,
                                       "AssertionOnBehalfOfPID": 4242], owner: 300)
        XCTAssertEqual(a.ownerPid, 300)
        XCTAssertEqual(a.beneficiaryPid, 4242)
    }
}

final class PowerMetricsTests: XCTestCase {
    private func plist(pressure: String, freq: Double, idle: [Double]) -> String {
        let cpus = idle.enumerated().map { "<dict><key>cpu</key><integer>\($0.offset)</integer><key>idle_ratio</key><real>\($0.element)</real></dict>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>thermal_pressure</key><string>\(pressure)</string>
        <key>processor</key><dict>
        <key>clusters</key><array><dict><key>name</key><string>E-Cluster</string><key>freq_hz</key><real>\(freq)</real>
        <key>idle_ratio</key><real>0</real><key>cpus</key><array>\(cpus)</array></dict></array>
        <key>cpu_power</key><real>4862.15</real><key>gpu_power</key><real>369.2</real><key>ane_power</key><real>0</real>
        </dict>
        <key>gpu</key><dict><key>freq_hz</key><real>338</real><key>idle_ratio</key><real>0.85</real></dict>
        </dict></plist>
        """
    }

    func testSamplesAreReassembledFromLines() {
        let text = plist(pressure: "Nominal", freq: 2_034_590_000, idle: [0.5, 0.7]) + "\n\0" + plist(pressure: "Heavy", freq: 1e9, idle: [0.1])
        var assembler = PowerMetrics.Assembler()
        let lines = text.split(separator: "\n").map(String.init)
        let first = assembler.feed(Array(lines.prefix(5)))
        let rest = assembler.feed(Array(lines.dropFirst(5)))
        let samples = first + rest
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].thermalPressure, "Nominal")
        XCTAssertEqual(samples[0].thermalPressureLevel, 0)
        XCTAssertEqual(samples[0].clusters.first?.name, "E-Cluster")
        XCTAssertEqual(samples[0].clusters.first?.frequencyHz, 2_034_590_000)
        XCTAssertEqual(samples[0].clusters.first?.activeRatio ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(samples[0].cpuPower ?? 0, 4.86215, accuracy: 1e-9)
        XCTAssertEqual(samples[0].gpuFrequencyMHz, 338)
        XCTAssertEqual(samples[1].thermalPressureLevel, 2)
    }
}
