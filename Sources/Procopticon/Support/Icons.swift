import AppKit
import ProcopticonCore
import UniformTypeIdentifiers

/// Process and file icons. Loading an icon from disk can take milliseconds, so cache misses
/// return a placeholder immediately and load in the background; tables refresh when icons arrive.
enum ProcessIcons {
    static let didLoadNotification = Notification.Name("Procopticon.IconsLoaded")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    nonisolated(unsafe) private static var pending: Set<String> = []
    nonisolated(unsafe) private static var notifyScheduled = false
    private static let queue = DispatchQueue(label: "icons", qos: .utility, attributes: .concurrent)
    private static let size = NSSize(width: 16, height: 16)

    static let executable: NSImage = rendered(NSWorkspace.shared.icon(for: .unixExecutable))

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

    /// The icon as plain bitmaps at the sizes cells and the hover card draw (16 pt at 1x and 2x,
    /// and 4x for the card's 32 pt at 2x). Workspace icons hold many representations, some rendered on demand, and
    /// drawing one picks, scales and color-converts a representation every time; table cells
    /// redraw constantly, so that was a large part of each frame.
    static func rendered(_ icon: NSImage) -> NSImage {
        let image = NSImage(size: size)
        for pixels in [16, 32, 64] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            // Same point size for all; the pixel count is the density (1x, 2x, 4x).
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
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
                let image = rendered(NSWorkspace.shared.icon(forFile: path))
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
