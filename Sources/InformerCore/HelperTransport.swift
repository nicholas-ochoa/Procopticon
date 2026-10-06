import Darwin
import Foundation

/// Length-prefixed JSON framing over a stream socket.
enum Framing {
    static func write(_ fd: Int32, _ data: Data) -> Bool {
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        return writeAll(fd, header) && writeAll(fd, data)
    }

    static func read(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length < 512 * 1024 * 1024 else { return nil }
        return readExactly(fd, Int(length))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        if count == 0 { return data }
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }
}

private func makeUnixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

/// Root helper: serves requests from exactly one client process (pid + uid verified per connection).
public final class HelperServer {
    private let socketPath: String
    private let clientPid: pid_t
    private let clientUid: uid_t
    private let executor = PrivilegedExecutor(restrictTools: true)
    private var listenFd: Int32 = -1
    private var exitSource: DispatchSourceProcess?

    public init(socketPath: String, clientPid: pid_t, clientUid: uid_t) {
        self.socketPath = socketPath
        self.clientPid = clientPid
        self.clientUid = clientUid
    }

    public func run() -> Never {
        // Exit when the owning app goes away.
        let source = DispatchSource.makeProcessSource(identifier: clientPid, eventMask: .exit, queue: .global())
        source.setEventHandler { [socketPath] in
            unlink(socketPath)
            exit(0)
        }
        source.resume()
        exitSource = source
        if kill(clientPid, 0) != 0 {
            exit(0)
        }

        unlink(socketPath)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0, var addr = makeUnixAddress(socketPath) else {
            fatal("socket: \(String(cString: strerror(errno)))")
        }
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0 else {
            fatal("bind \(socketPath): \(String(cString: strerror(errno)))")
        }
        // Only the client user may connect (plus the per-connection peer checks below).
        chown(socketPath, clientUid, 0)
        chmod(socketPath, 0o600)
        guard listen(listenFd, 16) == 0 else {
            fatal("listen: \(String(cString: strerror(errno)))")
        }
        signal(SIGPIPE, SIG_IGN)
        while true {
            let fd = accept(listenFd, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                fatal("accept: \(String(cString: strerror(errno)))")
            }
            guard verifyPeer(fd) else {
                close(fd)
                continue
            }
            Thread.detachNewThread { [executor] in
                Self.serve(fd: fd, executor: executor)
            }
        }
    }

    private func verifyPeer(_ fd: Int32) -> Bool {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) == 0, cred.cr_uid == clientUid else {
            return false
        }
        var peerPid: pid_t = 0
        len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPid, &len) == 0, peerPid == clientPid else {
            return false
        }
        return true
    }

    private static func serve(fd: Int32, executor: PrivilegedExecutor) {
        defer { close(fd) }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        while let data = Framing.read(fd) {
            let response: PrivilegedResponse
            var shutdown = false
            if let request = try? decoder.decode(PrivilegedRequest.self, from: data) {
                if case .shutdown = request { shutdown = true }
                response = executor.handle(request)
            } else {
                response = .failure(PrivilegedError(code: EINVAL, message: "Malformed request"))
            }
            guard let out = try? encoder.encode(response), Framing.write(fd, out) else {
                return
            }
            if shutdown {
                exit(0)
            }
        }
    }

    private func fatal(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("informer-helper: " + message + "\n").utf8))
        exit(1)
    }
}

/// Client side of the helper connection. Keeps a small pool so long-running requests (e.g. vmmap)
/// don't stall periodic sampling.
public final class HelperClient: @unchecked Sendable {
    public let socketPath: String
    private let lock = NSLock()
    private var idle: [Int32] = []
    private let encoder = JSONEncoder()

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        idle.forEach { close($0) }
    }

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PrivilegedError(errno: errno, context: "socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var addr = makeUnixAddress(socketPath) else {
            close(fd)
            throw PrivilegedError(code: ENAMETOOLONG, message: "Socket path too long")
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            close(fd)
            throw PrivilegedError(errno: err, context: "Connecting to helper")
        }
        return fd
    }

    public func send(_ request: PrivilegedRequest) throws -> PrivilegedResponse {
        lock.lock()
        var fd = idle.popLast()
        lock.unlock()
        if fd == nil {
            fd = try connectSocket()
        }
        guard let fd else { throw PrivilegedError(code: EIO, message: "No helper connection") }
        let data = try encoder.encode(request)
        guard Framing.write(fd, data), let reply = Framing.read(fd) else {
            close(fd)
            throw PrivilegedError(code: EPIPE, message: "Lost connection to the privileged helper.")
        }
        lock.lock()
        idle.append(fd)
        lock.unlock()
        return try JSONDecoder().decode(PrivilegedResponse.self, from: reply)
    }

    public func ping() -> Bool {
        if case .pong(let uid, _)? = try? send(.ping) {
            return uid == 0
        }
        return false
    }
}
