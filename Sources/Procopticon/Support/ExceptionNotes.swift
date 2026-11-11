import Foundation
import ObjectiveC
import os

/// Writes down every Objective-C exception as it is thrown: its name, its reason and where it was
/// thrown from.
///
/// AppKit catches an exception thrown while a window lays out and ends the app, and the crash
/// report it leaves has neither the reason nor the place: only AppKit's own frames, from where
/// it was caught. Three launches in a row ended that way with nothing to say why. This keeps what
/// the report loses, in ~/Library/Logs/Procopticon/exceptions.log (and the system log), on this
/// Mac only.
enum ExceptionNotes {
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Procopticon", category: "exceptions")
    /// The file is started again when it has grown past this.
    private static let sizeLimit = 256 * 1024
    private static let noting = NSString(string: "Procopticon.ExceptionNotes.noting")

    private static var file: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Procopticon/exceptions.log")
    }

    static func install() {
        _ = objc_setExceptionPreprocessor { exception in
            if let exception = exception as? NSException {
                ExceptionNotes.note(exception)
            }
            return exception
        }
    }

    fileprivate static func note(_ exception: NSException) {
        // Anything thrown while noting one is let through, not noted in turn.
        let thread = Thread.current.threadDictionary
        guard thread[noting] == nil else { return }
        thread[noting] = true
        defer { thread.removeObject(forKey: noting) }

        let stack = Thread.callStackSymbols.dropFirst(3).prefix(60).joined(separator: "\n")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let text = """
            \(ISO8601DateFormatter().string(from: Date())) build \(version) \(Thread.isMainThread ? "main thread" : "background thread")
            \(exception.name.rawValue): \(exception.reason ?? "(no reason)")
            \(stack)


            """
        logger.fault("\(exception.name.rawValue, privacy: .public): \(exception.reason ?? "", privacy: .public)\n\(stack, privacy: .public)")
        FileHandle.standardError.write(Data(text.utf8))
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > sizeLimit {
            try? FileManager.default.removeItem(at: file)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }
}
