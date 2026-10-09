import XCTest
@testable import ProcopticonCore

final class SensorMonitorTests: XCTestCase {
    func testParsesControlCenterAttributions() {
        let line = #"{"eventMessage":"Active activity attributions changed to [\"mic:com.microsoft.teams2\", \"scr:com.mitchellh.ghostty\"]","subsystem":"com.apple.controlcenter"}"#
        XCTAssertEqual(SensorMonitor.parseAttributions(line), ["mic:com.microsoft.teams2", "scr:com.mitchellh.ghostty"])
        let none = #"{"eventMessage":"Active activity attributions changed to []"}"#
        XCTAssertEqual(SensorMonitor.parseAttributions(none), [])
        XCTAssertNil(SensorMonitor.parseAttributions("Filtering the log data using …"))
    }

    func testUseByPidAndByApp() {
        var s = SensorSnapshot()
        s.microphonePids = [42]
        s.cameraApps = ["us.zoom.xos"]
        s.screenRecordingApps = ["us.zoom.xos"]
        XCTAssertEqual(s.use(pid: 42, bundleIdentifier: nil, isAppMainExecutable: false), .microphone)
        XCTAssertEqual(s.use(pid: 7, bundleIdentifier: "us.zoom.xos", isAppMainExecutable: true), [.camera, .screenRecording])
        XCTAssertEqual(s.use(pid: 8, bundleIdentifier: "us.zoom.xos", isAppMainExecutable: false), [], "helpers inside the app aren't attributed")
        XCTAssertEqual(SensorUse([.microphone, .camera]).names, ["microphone", "camera"])
    }
}
