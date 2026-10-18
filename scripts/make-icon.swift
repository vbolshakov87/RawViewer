// Draws RawViewer's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]
// Original artwork drawn with Core Graphics (no SF Symbols: their license forbids icon use).
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body: macOS icon grid, 824 pt rounded square centred on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0x1B2233)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x34466A), color(0x121827)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let c = CGPoint(x: 512, y: 512)
    // Lens barrel ring.
    let ring = CGGradient(colorsSpace: space, colors: [color(0xE6E9EF), color(0x7D8596), color(0xC9CED8)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 318, y: c.y - 318, width: 636, height: 636))
    ctx.addEllipse(in: CGRect(x: c.x - 276, y: c.y - 276, width: 552, height: 552))
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(ring, start: CGPoint(x: 300, y: 830), end: CGPoint(x: 724, y: 194), options: [])
    ctx.restoreGState()

    // Dark glass behind the aperture.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 276, y: c.y - 276, width: 552, height: 552)); ctx.clip()
    let glass = CGGradient(colorsSpace: space, colors: [color(0x2A3550), color(0x05070C)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glass, startCenter: CGPoint(x: 470, y: 580), startRadius: 0, endCenter: c, endRadius: 290, options: [])

    // Light through a six-blade aperture: warm gradient inside a hexagon.
    let hexRadius: CGFloat = 132
    let hex = CGMutablePath()
    var vertices: [CGPoint] = []
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3 + .pi / 12
        vertices.append(CGPoint(x: c.x + cos(a) * hexRadius, y: c.y + sin(a) * hexRadius))
    }
    hex.addLines(between: vertices); hex.closeSubpath()
    ctx.saveGState()
    ctx.addPath(hex); ctx.clip()
    let light = CGGradient(colorsSpace: space, colors: [color(0xFFD27A), color(0xFF7A59), color(0xC2408A)] as CFArray,
                           locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(light, start: CGPoint(x: c.x - 90, y: c.y + 130), end: CGPoint(x: c.x + 90, y: c.y - 130), options: [])
    ctx.restoreGState()

    // Blade edges: from each hexagon corner, a line along the next side out to the glass edge.
    ctx.setStrokeColor(color(0x9AA6C2, 0.55)); ctx.setLineWidth(7); ctx.setLineCap(.round)
    for i in 0..<6 {
        let p = vertices[i], q = vertices[(i + 1) % 6]
        let dx = q.x - p.x, dy = q.y - p.y, len = (dx * dx + dy * dy).squareRoot()
        ctx.move(to: p)
        ctx.addLine(to: CGPoint(x: p.x - dx / len * 250, y: p.y - dy / len * 250))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Glass highlight.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 276, y: c.y - 276, width: 552, height: 552)); ctx.clip()
    let shine = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.38), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(shine, startCenter: CGPoint(x: 400, y: 660), startRadius: 0,
                           endCenter: CGPoint(x: 400, y: 660), endRadius: 150, options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let url = iconset.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, drawIcon(size: base * scale), nil)
        CGImageDestinationFinalize(dest)
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
