// Renders the FastCleanup app icon to a 1024×1024 PNG using AppKit/CoreGraphics.
// No external image tools required. Usage: swift scripts/AppIcon.swift <out.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let px = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("Could not allocate bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let size = CGFloat(px)

// Rounded-rect "squircle" inset from the canvas, per the macOS icon grid.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.2237
let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Blue brand gradient (top light → bottom deep), matching the app tint.
ctx.saveGState()
ctx.addPath(body)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 0.36, green: 0.61, blue: 1.00, alpha: 1),
    CGColor(srgbRed: 0.11, green: 0.31, blue: 0.86, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Soft top gloss for depth.
let gloss = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: 0, y: size * 0.5), options: [])
ctx.restoreGState()

// Hairline inner stroke for crispness on light backgrounds.
ctx.saveGState()
ctx.addPath(body)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// Centered white "sparkles" glyph (same symbol as the menu-bar icon), with a soft shadow.
let cfg = NSImage.SymbolConfiguration(pointSize: 500, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = symbol.size
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    symbol.isTemplate = true
    let r = NSRect(origin: .zero, size: s)
    symbol.draw(in: r)
    NSColor.white.set()
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
    let dest = CGRect(x: (size - s.width) / 2, y: (size - s.height) / 2,
                      width: s.width, height: s.height)
    tinted.draw(in: dest)
    ctx.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encode failed")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(px)×\(px))")
