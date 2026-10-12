// Draws the app icon (an original design, not Apple's Notes icon) and writes an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>   then: iconutil -c icns <output.iconset>
import AppKit
import CoreGraphics

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let color = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: color,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Squircle-like rounded square on the macOS icon grid (824 pt inside 1024).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(red: 0.13, green: 0.16, blue: 0.32, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: color, colors: [
        CGColor(red: 0.20, green: 0.27, blue: 0.62, alpha: 1), CGColor(red: 0.09, green: 0.11, blue: 0.27, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A tilted sheet of paper with a warm header band.
    ctx.translateBy(x: 512, y: 520)
    ctx.rotate(by: -0.10)
    let sheet = CGRect(x: -230, y: -270, width: 460, height: 540)
    let sheetPath = CGPath(roundedRect: sheet, cornerWidth: 46, cornerHeight: 46, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(sheetPath)
    ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(sheetPath)
    ctx.clip()
    ctx.setFillColor(CGColor(red: 1.0, green: 0.74, blue: 0.20, alpha: 1))
    ctx.fill(CGRect(x: -230, y: 160, width: 460, height: 110))
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(red: 0.62, green: 0.66, blue: 0.78, alpha: 1))
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    for (i, width) in [300.0, 340.0, 250.0].enumerated() {
        let y = 70 - CGFloat(i) * 80
        ctx.move(to: CGPoint(x: -170, y: y))
        ctx.addLine(to: CGPoint(x: -170 + width, y: y))
    }
    ctx.strokePath()

    // A connector badge: two linked rings, for "connected to an assistant".
    ctx.rotate(by: 0.10)
    let badge = CGRect(x: 95, y: -330, width: 210, height: 210)
    ctx.setFillColor(CGColor(red: 0.27, green: 0.80, blue: 0.62, alpha: 1))
    ctx.fillEllipse(in: badge)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(20)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 135, y: -250, width: 80, height: 50), cornerWidth: 25, cornerHeight: 25, transform: nil))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 185, y: -250, width: 80, height: 50), cornerWidth: 25, cornerHeight: 25, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
