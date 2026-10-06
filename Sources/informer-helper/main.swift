import Darwin
import Foundation
import InformerCore

// Privileged helper for Process Informer.
//
// Started as root through the macOS authorization dialog:
//   informer-helper --serve --socket <path> --client-pid <pid> --client-uid <uid>
// It accepts connections only from <client-pid> running as <client-uid>, and exits when that
// process exits.

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: informer-helper --serve --socket <path> --client-pid <pid> --client-uid <uid>\n".utf8))
    exit(64)
}

var socketPath: String?
var clientPid: pid_t?
var clientUid: uid_t?
var serve = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--serve": serve = true
    case "--socket": socketPath = args.next()
    case "--client-pid": clientPid = args.next().flatMap { pid_t($0) }
    case "--client-uid": clientUid = args.next().flatMap { uid_t($0) }
    default: usage()
    }
}

guard serve, let socketPath, let clientPid, let clientUid else {
    usage()
}
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("informer-helper: must run as root\n".utf8))
    exit(77)
}

// Detach from the authorization trampoline's session so we outlive it.
setsid()
HelperServer(socketPath: socketPath, clientPid: clientPid, clientUid: clientUid).run()
