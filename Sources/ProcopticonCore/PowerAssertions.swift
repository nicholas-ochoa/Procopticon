import Foundation
import IOKit.pwr_mgt

/// What a process's power assertions keep awake.
public enum SleepPrevention: Int, Comparable, Sendable {
    /// The Mac stays awake; the display may still sleep.
    case system = 1
    /// The display stays on, and so the Mac stays awake too.
    case display = 2

    public static func < (a: SleepPrevention, b: SleepPrevention) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .display: return "Display"
        }
    }
}

/// One power assertion, as powerd reports it (`pmset -g assertions`).
public struct PowerAssertion: Hashable, Sendable {
    public var id: Int
    /// The type in effect, e.g. PreventUserIdleSystemSleep (legacy names are mapped to it).
    public var type: String
    /// The type the process asked for, when it used a legacy name such as NoIdleSleepAssertion.
    public var requestedType: String?
    public var name: String
    public var details: String?
    /// The explanation shown to users, if the process gave one.
    public var reason: String?
    public var started: Date?
    /// Seconds after which the assertion ends by itself, if it has a timeout.
    public var timeout: TimeInterval?
    public var timeLeft: TimeInterval?
    /// False for an assertion the process created but turned off.
    public var isOn: Bool
    /// The process that holds the assertion.
    public var ownerPid: Int32
    /// The process it was created for, when another holds it on its behalf (e.g. coreaudiod
    /// while an app plays sound).
    public var beneficiaryPid: Int32?

    /// Types that keep the Mac awake, and what they keep on.
    public static let sleepTypes: [String: SleepPrevention] = [
        "PreventUserIdleSystemSleep": .system,
        "PreventSystemSleep": .system,
        "NoIdleSleepAssertion": .system,
        "PreventUserIdleDisplaySleep": .display,
        "NoDisplaySleepAssertion": .display,
    ]

    public var sleepPrevention: SleepPrevention? {
        isOn ? Self.sleepTypes[type] : nil
    }

    /// A plain-language description of the type.
    public var typeDescription: String {
        switch type {
        case "PreventUserIdleSystemSleep": return "Keeps the Mac from idle sleep"
        case "PreventSystemSleep": return "Keeps the Mac from sleeping, even when asked to"
        case "PreventUserIdleDisplaySleep": return "Keeps the display on"
        case "UserIsActive": return "Reports user activity (wakes the display)"
        case "BackgroundTask": return "Runs a background task"
        case "ApplePushServiceTask": return "Handles a push notification"
        case "NetworkClientActive": return "Keeps the network active"
        case "SoftwareUpdateTask": return "Installs software updates"
        case "ExternalMedia": return "Keeps external media mounted"
        case "PreventDiskIdle": return "Keeps disks spinning"
        default: return ""
        }
    }
}

public enum PowerAssertions {
    /// Every process's assertions, by PID. An assertion held on behalf of another process is
    /// listed under both. Costs one request to powerd.
    public static func byProcess() -> [Int32: [PowerAssertion]] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return [:]
        }
        var result: [Int32: [PowerAssertion]] = [:]
        for (pidNumber, list) in dict {
            let owner = pidNumber.int32Value
            for raw in list {
                let a = parse(raw, owner: owner)
                result[owner, default: []].append(a)
                if let other = a.beneficiaryPid, other != owner {
                    result[other, default: []].append(a)
                }
            }
        }
        return result
    }

    static func parse(_ d: [String: Any], owner: Int32) -> PowerAssertion {
        func number(_ key: String) -> Double? { (d[key] as? NSNumber)?.doubleValue }
        // Whoever takes the assertion supplies these, and powerd passes them on unchecked: a
        // value no PID or identifier can have is dropped, not converted (which would trap).
        func integer<T: FixedWidthInteger>(_ key: String) -> T? { number(key).flatMap { T(exactly: $0.rounded()) } }
        func string(_ key: String) -> String? {
            guard let s = d[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        let requested = string("AssertType") ?? ""
        let type = string("AssertionTrueType") ?? requested
        let timeout = number("TimeoutSeconds").flatMap { $0 > 0 ? $0 : nil }
        return PowerAssertion(
            id: integer("AssertionId") ?? 0,
            type: type,
            requestedType: requested != type && !requested.isEmpty ? requested : nil,
            name: string("AssertName") ?? "",
            details: string("Details"),
            reason: string("HumanReadableReason"),
            started: d["AssertStartWhen"] as? Date,
            timeout: timeout,
            timeLeft: timeout == nil ? nil : number("AssertTimeoutTimeLeft"),
            isOn: (number("AssertLevel") ?? 255) > 0,
            ownerPid: integer("AssertPID") ?? owner,
            beneficiaryPid: integer("AssertionOnBehalfOfPID"))
    }
}

public extension Array where Element == PowerAssertion {
    /// The strongest sleep prevention among these assertions.
    var sleepPrevention: SleepPrevention? {
        compactMap(\.sleepPrevention).max()
    }
}
