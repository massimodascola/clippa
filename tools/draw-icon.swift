import AppKit

// Draws the Clippa icon (1024x1024) and saves it as a PNG.
// Usage: swift tools/draw-icon.swift <file.png>
//
// A bold white "C" holding a copied card, on a pink-to-violet gradient.
// It follows the macOS icon grid: an 824-point rounded shape centered in a
// 1024 canvas, with a 100-point margin for the shadow. The C is open on
// the right, so its circle is not its visual center: the glyph is drawn
// once off screen, measured, and moved so its real outline is centered.

let side: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let top: UInt32 = 0xF0509A     // pink
let bottom: UInt32 = 0x6D3BE0  // violet

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Top-down coordinates, to reason as on paper.
func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: side - y - height, width: width, height: height)
}

func shadow(_ alpha: CGFloat, blur: CGFloat, y: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.set()
}

/// The C and the card, around (512, 512) moved by `offset`.
func drawGlyph(offset: NSPoint, withShadows: Bool) {
    let center = NSPoint(x: 512 + offset.x, y: 512 + offset.y)

    NSGraphicsContext.saveGraphicsState()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: 248, startAngle: 48, endAngle: 312)
    arc.lineWidth = 96
    arc.lineCapStyle = .round
    if withShadows { shadow(0.25, blur: 24, y: -10) }
    NSColor.white.setStroke()
    arc.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The card sits in the C, a little towards its opening, slightly tilted.
    let card = NSBezierPath(roundedRect: NSRect(x: -88, y: -110, width: 176, height: 220), xRadius: 30, yRadius: 30)
    let place = NSAffineTransform()
    place.translateX(by: center.x + 48, yBy: center.y)
    place.rotate(byDegrees: -8)

    NSGraphicsContext.saveGraphicsState()
    place.concat()
    if withShadows { shadow(0.28, blur: 20, y: -8) }
    color(0xFFFFFF, 0.96).setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    place.concat()
    card.addClip()
    color(bottom, 0.9).setFill()
    NSRect(x: -88, y: 60, width: 176, height: 50).fill()
    color(0x1F2937, 0.2).setFill()
    for (row, width) in [CGFloat(0.75), 0.55, 0.65].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: -60, y: 20 - CGFloat(row) * 40, width: 120 * width, height: 18),
                     xRadius: 9, yRadius: 9).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// Bounding box of what `drawGlyph` paints, measured on a bitmap.
func glyphBounds() -> NSRect {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawGlyph(offset: .zero, withShadows: false)
    NSGraphicsContext.restoreGraphicsState()
    var minX = Int(side), maxX = 0, minY = Int(side), maxY = 0
    for y in 0..<Int(side) {
        for x in 0..<Int(side) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Bitmap rows go top-down; convert to bottom-up drawing coordinates.
    return NSRect(x: CGFloat(minX), y: side - CGFloat(maxY) - 1,
                  width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

let bounds = glyphBounds()
let offset = NSPoint(x: (side / 2 - bounds.midX).rounded(), y: (side / 2 - bounds.midY).rounded())
print("Glyph bounds \(bounds), moved by \(offset)")

let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
    let shape = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: 185, yRadius: 185)

    // Shadow under the shape
    NSGraphicsContext.saveGraphicsState()
    shadow(0.30, blur: 24, y: -10)
    color(bottom).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: pink at the top to violet at the bottom, with a soft highlight
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: color(top), ending: color(bottom))!.draw(in: rect(100, 100, 824, 824), angle: -90)
    NSGradient(starting: color(0xFFFFFF, 0.16), ending: color(0xFFFFFF, 0))!.draw(in: rect(100, 100, 824, 320), angle: -90)
    drawGlyph(offset: offset, withShadows: true)
    NSGraphicsContext.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not draw the icon")
}
try! png.write(to: URL(fileURLWithPath: output))
print("Saved \(output)")
