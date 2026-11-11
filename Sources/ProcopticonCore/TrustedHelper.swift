import CSysInfo
import Darwin
import Foundation

/// Running the helper from where only root can change it.
///
/// The helper in the application bundle can usually be replaced by anything running as the user,
/// so root never runs that file. Root copies it into `HelperSocket.directory`, checks that the
/// copy is signed by the team that signed the running app, and runs the copy. The copy is also
/// what the helper runs again for memory-region scans (`IsolatedScanner`).
public enum TrustedHelper {
    /// Where root keeps the copy of the helper serving the app with this PID.
    public static func path(clientPid: pid_t) -> String {
        "\(HelperSocket.directory)/helper-\(clientPid)"
    }

    /// What the helper is checked against before root runs it.
    public enum Check: Equatable, Sendable {
        /// The code requirement the copy must meet.
        case requirement(String)
        /// This build has no developer team (ad-hoc signed), so there is nothing to check against.
        case noTeam
        /// This build has a team, or may have, and the requirement couldn't be worked out. The
        /// helper is not started: skipping the check here would run an unchecked helper as root
        /// in exactly the builds that promise the check.
        case unknown
    }

    /// The check for the helper of this process, from the kernel's record of what is running, not
    /// from what is now on disk.
    public static func ownCheck() -> Check {
        var team = [CChar](repeating: 0, count: 512)
        var identifier = [CChar](repeating: 0, count: 512)
        let teamStatus = si_cs_identity(getpid(), 1, &team, Int32(team.count))
        let identifierStatus = si_cs_identity(getpid(), 0, &identifier, Int32(identifier.count))
        return check(teamStatus: teamStatus, team: String(cString: team),
                     identifierStatus: identifierStatus, identifier: String(cString: identifier))
    }

    /// The kernel answers ENOENT for the team of an ad-hoc signed process; any other failure, or
    /// values no requirement can be written for, leave the check unknown.
    static func check(teamStatus: Int32, team: String, identifierStatus: Int32, identifier: String) -> Check {
        if teamStatus == -ENOENT { return .noTeam }
        guard teamStatus == 0, identifierStatus == 0,
              let requirement = requirement(team: team, appIdentifier: identifier) else { return .unknown }
        return .requirement(requirement)
    }

    /// The code requirement the helper must meet: Apple-issued certificate of the same team, and
    /// the helper's identifier (the app's, plus ".helper"; see scripts/build-app.sh). Nil when the
    /// values aren't ones a signature can have, so nothing odd reaches the requirement text.
    public static func requirement(team: String, appIdentifier: String) -> String? {
        let teamCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !team.isEmpty, team.unicodeScalars.allSatisfy(teamCharacters.contains),
              !appIdentifier.isEmpty, appIdentifier.unicodeScalars.allSatisfy(identifierCharacters.contains) else {
            return nil
        }
        return "anchor apple generic and identifier \"\(appIdentifier).helper\" and certificate leaf[subject.OU] = \"\(team)\""
    }



    /// The most of the bundle's helper that root copies: several times its size. What stands in
    /// its place when root reads it could be anything, of any length.
    static let copyLimit = 64 * 1024 * 1024

    /// The commands root runs to start the helper: copy it, check the copy, run the copy. The
    /// check is on the copy, which nobody else can change, so there is nothing to swap in between.
    ///
    /// The file in the bundle can be swapped for a link to something only root may read between
    /// any test of it and the copy, so the copy never depends on such a test: only root can read
    /// the copy (umask 077, mode 0700), before the check and after it, and it has a size limit.
    public static func startScript(helper: String, clientPid: pid_t, clientUid: uid_t, requirement: String?) -> String {
        let directory = HelperSocket.directory
        let copy = path(clientPid: clientPid).shellQuoted
        let source = helper.shellQuoted
        var steps = [
            "umask 077",
            // /var/run is root's, so this directory can only be one root made.
            "/bin/mkdir -p \(directory) && /usr/sbin/chown 0:0 \(directory) && /bin/chmod 755 \(directory) || exit 1",
            "/bin/rm -f \(copy)",
            "if [ -L \(source) ] || [ ! -f \(source) ]; then echo 'The privileged helper is missing.' >&2; exit 1; fi",
            "/usr/bin/head -c \(copyLimit) \(source) > \(copy) && /bin/chmod 700 \(copy) || exit 1",
        ]
        if let requirement {
            steps.append("if ! /usr/bin/codesign --verify --strict \(("-R=" + requirement).shellQuoted) \(copy) >/dev/null 2>&1; then "
                + "/bin/rm -f \(copy); "
                + "echo 'The privileged helper is not signed by the developer of this copy of Procopticon, so it was not started.' >&2; "
                + "exit 1; fi")
        }
        // The helper and what it starts get the usual umask back.
        steps.append("umask 022")
        steps.append("\(copy) --serve --client-pid \(clientPid) --client-uid \(clientUid) >/dev/null 2>&1 &")
        return steps.joined(separator: "; ")
    }

    /// For an app that is itself running as root: copies the helper to where only root can change
    /// it, for memory-region scans. Returns the copy's path, or nil when it couldn't be made.
    public static func installCopy(of helper: String) -> String? {
        guard geteuid() == 0, HelperSocket.ensureDirectory() else { return nil }
        let copy = path(clientPid: getpid())
        unlink(copy)
        var st = stat()
        guard lstat(helper, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        guard copyfile(helper, copy, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0,
              chmod(copy, 0o755) == 0, isRootOnly(copy) else {
            unlink(copy)
            return nil
        }
        return copy
    }

    /// Removes the copy made for this process, if there is one.
    public static func removeOwnCopy() {
        guard geteuid() == 0 else { return }
        unlink(path(clientPid: getpid()))
    }

    /// Whether only root can change the file at `path`: it and its directory belong to root and
    /// nobody else may write to either. (The directories above are /var/run's, which are root's.)
    public static func isRootOnly(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == 0, st.st_mode & 0o022 == 0 else {
            return false
        }
        let directory = (path as NSString).deletingLastPathComponent
        guard lstat(directory, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == 0, st.st_mode & 0o022 == 0 else {
            return false
        }
        return true
    }
}

/// Running a tool that writes its report to a file, without a file anyone else could get at.
///
/// `sample` and `spindump` want a file to write to. When they run as root, a file in a directory
/// the user can write to could be swapped for a link, and root would write through it. So the
/// report goes into a new directory only the runner can open, and comes back as text.
public enum ToolReport {
    /// Stands in the arguments for the path of the report file.
    public static let placeholder = "{report-file}"

    static func run(_ tool: String, _ arguments: [String]) -> ToolOutput {
        guard let directory = makePrivateDirectory() else {
            return ToolOutput(status: -1, stdout: "", stderr: "Couldn't make a private directory for the report.")
        }
        defer { remove(directory) }
        let file = directory + "/report.txt"
        let output = ToolRunner.run(tool, arguments.map { $0 == placeholder ? file : $0 })
        let fd = open(file, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return output }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return output }
        return ToolOutput(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }

    /// A new directory (mode 0700) for the current user; root's is inside its own directory.
    static func makePrivateDirectory() -> String? {
        let base: String
        if geteuid() == 0 {
            guard HelperSocket.ensureDirectory() else { return nil }
            base = HelperSocket.directory
        } else {
            base = (NSTemporaryDirectory() as NSString).standardizingPath
        }
        var template = Array((base + "/report.XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { return nil }
        let directory = String(cString: template)
        lock.lock()
        directories.insert(directory)
        lock.unlock()
        return directory
    }

    private static let lock = NSLock()
    private static var directories = Set<String>()

    private static func remove(_ directory: String) {
        try? FileManager.default.removeItem(atPath: directory)
        lock.lock()
        directories.remove(directory)
        lock.unlock()
    }

    /// Removes the directories of reports still being written. For the helper as it exits, when
    /// the `defer` in `run` doesn't get to.
    public static func removeDirectories() {
        lock.lock()
        let all = directories
        lock.unlock()
        all.forEach(remove)
    }
}
