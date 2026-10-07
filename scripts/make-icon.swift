// Renders the app icon into an .iconset directory. Usage: swift make-icon.swift <artwork.png> <out.iconset>
//
// The artwork is a full-bleed square (no rounded corners, no shadow). It is placed on Apple's macOS icon
// grid (an 824 pt body on a 1024 pt canvas), clipped to the continuous-corner icon shape, given a subtle
// edge highlight and drop shadow, then downscaled with Lanczos for the smaller sizes.
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let artPath = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

guard let artSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: artPath) as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(artSource, 0, nil) else {
    FileHandle.standardError.write(Data("make-icon: cannot read \(artPath)\n".utf8))
    exit(1)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Apple's continuous ("squircle") rounded rectangle, the shape of macOS app icons.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    // Each corner is described in units of r, measured inward from that corner.
    func pt(_ cx: CGFloat, _ cy: CGFloat, _ sx: CGFloat, _ sy: CGFloat, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: cx + sx * x * r, y: cy + sy * y * r)
    }
    let p = CGMutablePath()
    let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (rect.maxX, rect.maxY, -1, -1), (rect.maxX, rect.minY, -1, 1),
        (rect.minX, rect.minY, 1, 1), (rect.minX, rect.maxY, 1, -1),
    ]
    p.move(to: CGPoint(x: rect.minX + 1.52866483 * r, y: rect.maxY))
    for (i, (cx, cy, sx, sy)) in corners.enumerated() {
        // Corners alternate between entering along a horizontal edge and along a vertical one.
        let horizontal = i % 2 == 0
        func c(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            horizontal ? pt(cx, cy, sx, sy, along, across) : pt(cx, cy, sx, sy, across, along)
        }
        p.addLine(to: c(1.52866483, 0))
        p.addCurve(to: c(0.66993427, 0.06549600), control1: c(1.08849323, 0), control2: c(0.86840689, 0))
        p.addLine(to: c(0.63149399, 0.07491100))
        p.addCurve(to: c(0.07491176, 0.63149399), control1: c(0.37282392, 0.16905899), control2: c(0.16906013, 0.37282401))
        p.addCurve(to: c(0, 1.52866483), control1: c(0, 0.86840701), control2: c(0, 1.08849299))
    }
    p.closeSubpath()
    return p
}

func renderMaster() -> CGImage {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = continuousRoundedRect(body, radius: 185.4)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.38))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(art, in: body)
    // Edge highlight: a thin inner rim, brighter at the top, as if lit from above.
    ctx.addPath(shape)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = CGGradient(colorsSpace: sRGB, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.05),
                                                     CGColor(gray: 1, alpha: 0.03)] as CFArray,
                         locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return ctx.makeImage()!
}

let master = renderMaster()
let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

func scaled(_ px: Int) -> CGImage {
    if px == master.width { return master }
    let filter = CIFilter.lanczosScaleTransform()
    filter.inputImage = CIImage(cgImage: master)
    filter.scale = Float(px) / Float(master.width)
    filter.aspectRatio = 1
    return ciContext.createCGImage(filter.outputImage!, from: CGRect(x: 0, y: 0, width: px, height: px),
                                   format: .RGBA8, colorSpace: sRGB)!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(cgImage: scaled(px))
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
