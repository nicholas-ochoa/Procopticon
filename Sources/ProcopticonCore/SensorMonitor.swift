import CoreAudio
import CoreMediaIO
import Foundation

/// Privacy-sensitive hardware a process is using.
public struct SensorUse: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let microphone = SensorUse(rawValue: 1)
    public static let camera = SensorUse(rawValue: 2)
    public static let screenRecording = SensorUse(rawValue: 4)

    public var names: [String] {
        var names: [String] = []
        if contains(.microphone) { names.append("microphone") }
        if contains(.camera) { names.append("camera") }
        if contains(.screenRecording) { names.append("screen recording") }
        return names
    }
}

/// What uses the microphone, camera and screen recording right now.
public struct SensorSnapshot: Sendable {
    /// Processes recording from an audio input, from Core Audio.
    public var microphonePids: Set<Int32> = []
    /// Apps Control Center shows by its privacy indicators, by bundle identifier.
    public var microphoneApps: Set<String> = []
    public var cameraApps: Set<String> = []
    public var screenRecordingApps: Set<String> = []

    /// What a process uses: by PID for the microphone, and by bundle for an app's main executable.
    public func use(pid: Int32, bundleIdentifier: String?, isAppMainExecutable: Bool) -> SensorUse {
        var use: SensorUse = []
        if microphonePids.contains(pid) { use.insert(.microphone) }
        if isAppMainExecutable, let id = bundleIdentifier {
            if microphoneApps.contains(id) { use.insert(.microphone) }
            if cameraApps.contains(id) { use.insert(.camera) }
            if screenRecordingApps.contains(id) { use.insert(.screenRecording) }
        }
        return use
    }
}

/// Finds the processes using the microphone, camera or screen recording.
///
/// * Microphone: Core Audio reports which processes are running audio input.
/// * Camera and screen recording: no API attributes them to processes. Control Center does, for its
///   privacy indicators, and logs each change ("Active activity attributions changed to
///   ["mic:com.example.app"]"); `start()` follows that message with `log stream`. Reading the log
///   needs an administrator account (or the root helper).
public final class SensorMonitor: @unchecked Sendable {
    public static let shared = SensorMonitor()

    static let attributionPredicate = #"process == "ControlCenter" AND category == "sensor-indicators" AND eventMessage BEGINSWITH "Active activity attributions changed""#

    private let lock = NSLock()
    /// Control Center's attributions as "type:bundle-id" (types seen: mic, cam, scr, loc).
    private var attributions: [String] = []
    private var haveLiveAttributions = false
    private var stream: ToolStream?
    private var started = false
    /// Core Audio process objects and their PIDs; the objects outlive samples.
    private var audioProcessPids: [AudioObjectID: pid_t] = [:]
    private var inputDevices: [AudioObjectID] = []
    private var inputDevicesChecked = Date.distantPast

    // MARK: Control Center attributions

    /// Starts following Control Center's attributions. Call once, on the main thread.
    @MainActor
    public func start() {
        guard !started else { return }
        started = true
        follow()
        // The latest change before now: Control Center only logs changes.
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let args = ["show", "--style", "ndjson", "--last", "1h", "--predicate", Self.attributionPredicate]
            guard case .tool(let out) = Elevation.shared.perform(.runTool(tool: "/usr/bin/log", arguments: args)) else { return }
            let latest = out.stdout.split(separator: "\n").reversed().lazy.compactMap { Self.parseAttributions(String($0)) }.first
            guard let self, let latest else { return }
            self.lock.withLock {
                if !self.haveLiveAttributions { self.attributions = latest }
            }
        }
    }

    @MainActor
    private func follow() {
        let stream = ToolStream(tool: "/usr/bin/log", arguments: ["stream", "--style", "ndjson", "--predicate", Self.attributionPredicate])
        self.stream = stream
        // The monitor lives as long as the app, so the closures hold it strongly.
        Task { @MainActor [self] in
            let error = await stream.start(prompt: false, interval: 1) { event in
                switch event {
                case .lines(let lines):
                    if let latest = lines.reversed().lazy.compactMap({ Self.parseAttributions($0) }).first {
                        self.lock.withLock {
                            self.attributions = latest
                            self.haveLiveAttributions = true
                        }
                    }
                case .finished:
                    self.retryLater()
                case .dropped:
                    break
                }
            }
            if error != nil {
                retryLater()
            }
        }
    }

    /// The log stream ended (the helper stopped, or the user can't read the log): try again later.
    @MainActor
    private func retryLater() {
        stream = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.stream == nil else { return }
            self.follow()
        }
    }

    /// The attribution list from one line of `log` ndjson output, or nil for other lines.
    static func parseAttributions(_ line: String) -> [String]? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let range = message.range(of: "changed to ") else {
            return nil
        }
        let list = message[range.upperBound...]
        guard let array = try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String] else { return nil }
        return array
    }

    // MARK: Sampling

    /// The current users of each sensor. Cheap unless an audio input is running. Call from one
    /// queue at a time (the process store's).
    public func sample() -> SensorSnapshot {
        var snapshot = SensorSnapshot()
        let current = lock.withLock { attributions }
        var unknown = Set<String>()
        for entry in current {
            guard let colon = entry.firstIndex(of: ":") else { continue }
            let type = entry[..<colon]
            let bundle = String(entry[entry.index(after: colon)...])
            switch type {
            case "mic": snapshot.microphoneApps.insert(bundle)
            case "cam": snapshot.cameraApps.insert(bundle)
            case "scr": snapshot.screenRecordingApps.insert(bundle)
            case "loc": break
            default: unknown.insert(bundle)
            }
        }
        // An indicator of another kind while a camera runs is taken to be the camera's.
        if !unknown.isEmpty, Self.cameraInUse() {
            snapshot.cameraApps.formUnion(unknown)
        }
        snapshot.microphonePids = microphonePids()
        return snapshot
    }

    private func microphonePids() -> Set<Int32> {
        if Date().timeIntervalSince(inputDevicesChecked) > 30 {
            inputDevices = Self.audioDevices().filter(Self.hasInput)
            inputDevicesChecked = Date()
        }
        // Only ask each process when some input device is running.
        guard inputDevices.contains(where: { Self.uint32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 }) else {
            return []
        }
        var objects: [AudioObjectID] = Self.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        objects = objects.filter { $0 != 0 }
        var pids = Set<Int32>()
        var known: [AudioObjectID: pid_t] = [:]
        for object in objects {
            let pid = audioProcessPids[object] ?? Self.pid(object)
            known[object] = pid
            if pid > 0, Self.uint32(object, kAudioProcessPropertyIsRunningInput) == 1 {
                pids.insert(pid)
            }
        }
        audioProcessPids = known
        return pids
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func pid(_ object: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : -1
    }

    private static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func audioDevices() -> [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        !array(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty
    }

    /// Whether any camera is running, from Core Media I/O. Only asked when needed: it loads the
    /// camera plug-ins into the process.
    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == 0 else { return false }
        for device in devices {
            var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var value: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &value) == 0, value != 0 {
                return true
            }
        }
        return false
    }
}
