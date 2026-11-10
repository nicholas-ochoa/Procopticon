import Darwin
import Foundation
import ProcopticonCore

// Privileged helper for Procopticon.
//
// Started as root through the macOS authorization dialog, from a copy only root can change (see
// TrustedHelper.startScript):
//   helper-<pid> --serve --client-pid <pid> --client-uid <uid>
// It listens at HelperSocket.path(clientPid:), accepts connections only from <client-pid> running
// as <client-uid>, and exits when that process exits.

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: procopticon-helper --serve --client-pid <pid> --client-uid <uid>\n".utf8))
    exit(64)
}

// One-shot isolated region scanner (see IsolatedScanner); runs with the caller's privileges.
if CommandLine.arguments.dropFirst().first == "--scan-regions" {
    IsolatedScanner.runChild()
}
// Where this executable really is, from the kernel. Scans run it again, as root when serving, so
// IsolatedScanner uses it only if nobody but root can change it.
var ownPathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
let ownPath: String? = proc_pidpath(getpid(), &ownPathBuffer, UInt32(ownPathBuffer.count)) > 0 ? String(cString: ownPathBuffer) : nil
IsolatedScanner.executablePath = ownPath

var clientPid: pid_t?
var clientUid: uid_t?
var serve = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--serve": serve = true
    case "--client-pid": clientPid = args.next().flatMap { pid_t($0) }
    case "--client-uid": clientUid = args.next().flatMap { uid_t($0) }
    default: usage()
    }
}

guard serve, let clientPid, let clientUid else {
    usage()
}
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("procopticon-helper: must run as root\n".utf8))
    exit(77)
}

// Detach from the authorization trampoline's session so we outlive it.
setsid()
// Root's copy of this executable, made for this client, goes away with the helper.
let expectedCopy = TrustedHelper.path(clientPid: clientPid)
let ownCopy = ownPath.flatMap { path in
    (path == expectedCopy || path == "/private" + expectedCopy) && TrustedHelper.isRootOnly(path) ? path : nil
}
HelperServer(clientPid: clientPid, clientUid: clientUid, ownCopy: ownCopy).run()
