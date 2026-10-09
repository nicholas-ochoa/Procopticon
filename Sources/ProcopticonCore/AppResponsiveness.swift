import Darwin
import Foundation

/// Whether GUI applications are responding to events, as the window server judges it: the same
/// test that shows the spinning wait cursor and Activity Monitor's "(Not Responding)".
///
/// There is no public API for this. The window server's own check (`SLSEventIsAppUnresponsive`)
/// is looked up at run time, so if a future macOS drops it, every app simply counts as responding.
public enum AppResponsiveness {
    private typealias MainConnection = @convention(c) () -> Int32
    /// The pointers are to a Carbon `ProcessSerialNumber` (two 32-bit words).
    private typealias IsUnresponsive = @convention(c) (Int32, UnsafeRawPointer) -> Bool
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private struct Functions {
        var connection: MainConnection
        var isUnresponsive: IsUnresponsive
        var processForPID: GetProcessForPID
    }

    private static let functions: Functions? = {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
        guard let connection = dlsym(skyLight, "SLSMainConnectionID"),
              let isUnresponsive = dlsym(skyLight, "SLSEventIsAppUnresponsive"),
              let processForPID = dlsym(hiServices, "GetProcessForPID") else {
            return nil
        }
        return Functions(connection: unsafeBitCast(connection, to: MainConnection.self),
                         isUnresponsive: unsafeBitCast(isUnresponsive, to: IsUnresponsive.self),
                         processForPID: unsafeBitCast(processForPID, to: GetProcessForPID.self))
    }()

    /// The applications among `pids` that aren't responding. Takes well under a millisecond per app.
    public static func unresponsive(among pids: some Sequence<Int32>) -> Set<Int32> {
        guard let f = functions else { return [] }
        let connection = f.connection()
        var result = Set<Int32>()
        for pid in pids {
            var psn: (UInt32, UInt32) = (0, 0)
            if f.processForPID(pid, &psn) == 0, f.isUnresponsive(connection, &psn) {
                result.insert(pid)
            }
        }
        return result
    }
}
