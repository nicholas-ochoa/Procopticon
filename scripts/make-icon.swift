// Renders the app icon into an .iconset directory. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.14, blue: 0.24, alpha: 1),
                        NSColor(srgbRed: 0.04, green: 0.06, blue: 0.11, alpha: 1)])!.draw(in: bg, angle: -90)
    // Graph grid
    NSColor(srgbRed: 0.3, green: 0.9, blue: 0.5, alpha: 0.12).setStroke()
    for i in 1..<6 {
        let y = rect.minY + rect.height * CGFloat(i) / 6
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.minX + radius * 0.3, y: y))
        p.line(to: NSPoint(x: rect.maxX - radius * 0.3, y: y))
        p.lineWidth = max(1, size / 256)
        p.stroke()
    }
    // CPU graph line
    let values: [CGFloat] = [0.18, 0.22, 0.2, 0.35, 0.3, 0.52, 0.46, 0.7, 0.58, 0.64, 0.42, 0.5, 0.78, 0.66, 0.72]
    let graph = NSBezierPath()
    let gx = rect.minX + rect.width * 0.1
    let gw = rect.width * 0.8
    for (i, v) in values.enumerated() {
        let pt = NSPoint(x: gx + gw * CGFloat(i) / CGFloat(values.count - 1), y: rect.minY + rect.height * (0.14 + v * 0.62))
        if i == 0 { graph.move(to: pt) } else { graph.line(to: pt) }
    }
    let fill = graph.copy() as! NSBezierPath
    fill.line(to: NSPoint(x: gx + gw, y: rect.minY + rect.height * 0.12))
    fill.line(to: NSPoint(x: gx, y: rect.minY + rect.height * 0.12))
    fill.close()
    NSColor(srgbRed: 0.25, green: 0.95, blue: 0.55, alpha: 0.22).setFill()
    fill.fill()
    NSColor(srgbRed: 0.35, green: 1.0, blue: 0.6, alpha: 1).setStroke()
    graph.lineWidth = max(1.5, size / 48)
    graph.lineJoinStyle = .round
    graph.stroke()
    // Magnifier
    let lensCenter = NSPoint(x: rect.minX + rect.width * 0.64, y: rect.minY + rect.height * 0.62)
    let r = rect.width * 0.17
    let lens = NSBezierPath(ovalIn: NSRect(x: lensCenter.x - r, y: lensCenter.y - r, width: r * 2, height: r * 2))
    NSColor(white: 1, alpha: 0.10).setFill()
    lens.fill()
    NSColor(white: 0.95, alpha: 1).setStroke()
    lens.lineWidth = max(1.5, size / 40)
    lens.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: lensCenter.x + r * 0.72, y: lensCenter.y - r * 0.72))
    handle.line(to: NSPoint(x: lensCenter.x + r * 1.55, y: lensCenter.y - r * 1.55))
    handle.lineWidth = max(2, size / 22)
    handle.lineCapStyle = .round
    handle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
