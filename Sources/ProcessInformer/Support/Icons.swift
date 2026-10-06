import AppKit
import InformerCore
import UniformTypeIdentifiers

/// Process and file icons. Loading an icon from disk can take milliseconds, so cache misses
/// return a placeholder immediately and load in the background; tables refresh when icons arrive.
enum ProcessIcons {
    static let didLoadNotification = Notification.Name("ProcessInformer.IconsLoaded")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    nonisolated(unsafe) private static var pending: Set<String> = []
    nonisolated(unsafe) private static var notifyScheduled = false
    private static let queue = DispatchQueue(label: "icons", qos: .utility, attributes: .concurrent)
    private static let size = NSSize(width: 16, height: 16)

    static let executable: NSImage = {
        let img = NSWorkspace.shared.icon(for: .unixExecutable)
        img.size = size
        return img
    }()

    static let kernel: NSImage = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Kernel") ?? executable

    static func icon(for record: ProcessRecord) -> NSImage {
        if record.pid == 0 {
            return kernel
        }
        guard let path = record.path, !path.isEmpty, let bundlePath = BundleInfoCache.enclosingBundlePath(path) else {
            return executable
        }
        let ext = (bundlePath as NSString).pathExtension
        var source = bundlePath
        if ext == "framework" || ext == "bundle" {
            // Frameworks rarely have meaningful icons; prefer the owning app if any.
            guard let app = BundleInfoCache.outermostApplicationPath(path) else { return executable }
            source = app
        }
        return cached(source) ?? executable
    }

    static func icon(forPath path: String) -> NSImage {
        cached(path) ?? executable
    }

    /// Returns a cached icon, or nil after scheduling a background load.
    private static func cached(_ path: String) -> NSImage? {
        lock.lock()
        if let image = cache[path] {
            lock.unlock()
            return image
        }
        let shouldLoad = pending.insert(path).inserted
        lock.unlock()
        if shouldLoad {
            queue.async {
                let image = NSWorkspace.shared.icon(forFile: path).copy() as! NSImage
                image.size = size
                lock.lock()
                cache[path] = image
                pending.remove(path)
                let schedule = !notifyScheduled
                notifyScheduled = true
                lock.unlock()
                if schedule {
                    // Coalesce many icon loads into one table refresh.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        lock.lock()
                        notifyScheduled = false
                        lock.unlock()
                        NotificationCenter.default.post(name: didLoadNotification, object: nil)
                    }
                }
            }
        }
        return nil
    }
}
