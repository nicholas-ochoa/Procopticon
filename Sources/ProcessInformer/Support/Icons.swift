import AppKit
import InformerCore
import UniformTypeIdentifiers

enum ProcessIcons {
    private static var cache: [String: NSImage] = [:]
    private static let size = NSSize(width: 16, height: 16)

    static let executable: NSImage = {
        let img = NSWorkspace.shared.icon(for: .unixExecutable)
        img.size = size
        return img
    }()

    static let kernel: NSImage = {
        let img = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Kernel") ?? executable
        return img
    }()

    static func icon(for record: ProcessRecord) -> NSImage {
        if record.pid == 0 {
            return kernel
        }
        guard let path = record.path, !path.isEmpty else {
            return executable
        }
        let bundlePath = BundleInfoCache.enclosingBundlePath(path)
        let key = bundlePath ?? "__exec__"
        if let cached = cache[key] {
            return cached
        }
        var image = executable
        if let bundlePath {
            let ext = (bundlePath as NSString).pathExtension
            if ext == "framework" || ext == "bundle" {
                // Frameworks rarely have meaningful icons; prefer the owning app if any.
                if let app = BundleInfoCache.outermostApplicationPath(path) {
                    image = NSWorkspace.shared.icon(forFile: app)
                }
            } else {
                image = NSWorkspace.shared.icon(forFile: bundlePath)
            }
            image = image.copy() as! NSImage
            image.size = size
        }
        cache[key] = image
        return image
    }

    static func icon(forPath path: String) -> NSImage {
        if let c = cache["file:" + path] { return c }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = size
        cache["file:" + path] = img
        return img
    }
}
