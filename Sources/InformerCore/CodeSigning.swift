import Foundation
import Security

public struct SigningInfo: Sendable {
    public enum Status: String, Sendable {
        case valid = "Valid"
        case adhoc = "Ad-hoc"
        case unsigned = "Unsigned"
        case invalid = "Invalid"
        case unknown = ""
    }

    public var status: Status
    public var statusDetail: String
    public var identifier: String?
    public var teamIdentifier: String?
    public var authorities: [String]
    public var isPlatformBinary: Bool
    public var isAppleSigned: Bool
    public var isNotarized: Bool
    public var hardenedRuntime: Bool
    public var flags: UInt32
    public var cdHash: String?
    public var format: String?
    public var signingDate: Date?
    public var entitlementsXML: String?
    public var entitlementKeys: [String]

    /// Leaf certificate common name, e.g. "Developer ID Application: Example Corp (ABCDE12345)".
    public var signer: String {
        if isPlatformBinary || authorities.first == "Software Signing" {
            return "Apple (platform)"
        }
        if status == .adhoc {
            return "Ad-hoc"
        }
        return authorities.first ?? ""
    }

    /// Organization extracted from the signing certificate.
    public var organization: String {
        if isAppleSigned {
            return "Apple Inc."
        }
        guard let leaf = authorities.first, let colon = leaf.firstIndex(of: ":") else {
            return ""
        }
        var org = leaf[leaf.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let paren = org.range(of: " (", options: .backwards), org.hasSuffix(")") {
            org = String(org[..<paren.lowerBound])
        }
        return org
    }

    public var verificationSummary: String {
        switch status {
        case .valid:
            if isPlatformBinary { return "Valid (Apple platform)" }
            if isNotarized { return "Valid (notarized)" }
            return "Valid"
        case .invalid: return "Invalid: \(statusDetail)"
        default: return status.rawValue
        }
    }
}

public enum CodeSigning {
    /// Static (on-disk) inspection of a Mach-O or bundle. Can take some time for large binaries.
    public static func inspect(path: String, validate: Bool = true) -> SigningInfo {
        var info = SigningInfo(
            status: .unknown, statusDetail: "", identifier: nil, teamIdentifier: nil, authorities: [],
            isPlatformBinary: false, isAppleSigned: false, isNotarized: false, hardenedRuntime: false,
            flags: 0, cdHash: nil, format: nil, signingDate: nil, entitlementsXML: nil, entitlementKeys: [])
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            info.status = .unknown
            return info
        }
        var cfInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        if SecCodeCopySigningInformation(code, flags, &cfInfo) == errSecSuccess, let dict = cfInfo as? [String: Any] {
            info.identifier = dict[kSecCodeInfoIdentifier as String] as? String
            info.teamIdentifier = dict[kSecCodeInfoTeamIdentifier as String] as? String
            info.format = dict[kSecCodeInfoFormat as String] as? String
            info.signingDate = dict[kSecCodeInfoTimestamp as String] as? Date ?? dict[kSecCodeInfoTime as String] as? Date
            if let csFlags = dict[kSecCodeInfoFlags as String] as? NSNumber {
                info.flags = csFlags.uint32Value
                info.hardenedRuntime = info.flags & CodeSigningFlags.runtime != 0
            }
            if let hash = dict[kSecCodeInfoUnique as String] as? Data {
                info.cdHash = hash.map { String(format: "%02x", $0) }.joined()
            }
            if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] {
                info.authorities = certs.compactMap { SecCertificateCopySubjectSummary($0) as String? }
            }
            if let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                info.entitlementKeys = ents.keys.sorted()
                if let data = try? PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0) {
                    info.entitlementsXML = String(decoding: data, as: UTF8.self)
                }
            }
            if let platform = dict["platform-identifier"] as? NSNumber, platform.intValue != 0 {
                info.isPlatformBinary = true
            }
            if dict[kSecCodeInfoIdentifier as String] == nil {
                info.status = .unsigned
                return info
            }
        } else {
            info.status = .unsigned
            return info
        }

        info.isAppleSigned = info.isPlatformBinary || check(code, requirement: "anchor apple")
        if info.authorities.isEmpty {
            info.status = .adhoc
        }
        guard validate else {
            if info.status == .unknown { info.status = .valid }
            return info
        }
        var errors: Unmanaged<CFError>?
        // Validate the executable for the native architecture only; checking every slice of every
        // universal binary multiplied disk reads for no benefit to the running process.
        let validateFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let rc = SecStaticCodeCheckValidityWithErrors(code, validateFlags, nil, &errors)
        if rc == errSecSuccess {
            if info.status != .adhoc {
                info.status = .valid
            }
            info.isNotarized = !info.isAppleSigned && check(code, requirement: "notarized")
        } else if rc == errSecCSUnsigned {
            info.status = .unsigned
        } else {
            info.status = .invalid
            let err = errors?.takeRetainedValue()
            info.statusDetail = err.map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(rc)"
        }
        return info
    }

    private static func check(_ code: SecStaticCode, requirement text: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else {
            return false
        }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), req) == errSecSuccess
    }

    /// Dynamic validation of a running process' code.
    public static func validateRunning(pid: Int32) -> (valid: Bool, detail: String) {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else {
            return (false, "Unable to obtain code object")
        }
        var errors: Unmanaged<CFError>?
        let rc = SecCodeCheckValidityWithErrors(code, [], nil, &errors)
        if rc == errSecSuccess {
            return (true, "Valid")
        }
        let err = errors?.takeRetainedValue()
        return (false, err.map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(rc)")
    }
}

/// Thread-safe cache of signing results keyed by executable path, computed in the background.
public final class SigningCache: @unchecked Sendable {
    public static let shared = SigningCache()
    public static let didUpdateNotification = Notification.Name("ProcessInformer.SigningCacheDidUpdate")

    private let lock = NSLock()
    private var results: [String: SigningInfo] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "signing", qos: .background, attributes: .concurrent)
    private let semaphore = DispatchSemaphore(value: 2)
    private var notifyScheduled = false

    public func info(for path: String) -> SigningInfo? {
        lock.lock()
        defer { lock.unlock() }
        if let r = results[path] {
            return r
        }
        if !pending.contains(path) {
            pending.insert(path)
            queue.async { [self] in
                semaphore.wait()
                let info = CodeSigning.inspect(path: path)
                semaphore.signal()
                lock.lock()
                results[path] = info
                pending.remove(path)
                let schedule = !notifyScheduled
                notifyScheduled = true
                lock.unlock()
                if schedule {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        lock.lock()
                        notifyScheduled = false
                        lock.unlock()
                        NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
                    }
                }
            }
        }
        return nil
    }

    public func cached(for path: String) -> SigningInfo? {
        lock.lock()
        defer { lock.unlock() }
        return results[path]
    }
}
