import Darwin
import Foundation
import ProcopticonCore

// Privileged helper for Procopticon.
//
// Started as root through the macOS authorization dialog:
//   procopticon-helper --serve --client-pid <pid> --client-uid <uid>
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
IsolatedScanner.executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]

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
HelperServer(clientPid: clientPid, clientUid: clientUid).run()
