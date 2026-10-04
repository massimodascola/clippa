import AppKit

// Draws the Clippa icon (1024x1024) and saves it as a PNG.
// Usage: swift tools/draw-icon.swift <file.png>
//
// Three cards fanned out like the shelf, white on warm orange. The front
// card has a colored header and lines of text, like a card in the app.
// It follows the macOS icon grid: an 824-point rounded shape centered in a
// 1024 canvas, with a 100-point margin for the shadow.

let side: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let orange: UInt32 = 0xFF7A1A

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func mix(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
    let x = a.usingColorSpace(.sRGB)!, y = b.usingColorSpace(.sRGB)!
    return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * amount,
                   green: x.greenComponent + (y.greenComponent - x.greenComponent) * amount,
                   blue: x.blueComponent + (y.blueComponent - x.blueComponent) * amount, alpha: 1)
}

// Top-down coordinates, to reason as on paper.
func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: side - y - height, width: width, height: height)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect(x, y, width, height), xRadius: radius, yRadius: radius)
}

/// A card of `width` x `height` centered on (cx, cy) in top-down
/// coordinates, rotated by `degrees` around its bottom center.
func drawCard(cx: CGFloat, cy: CGFloat, width: CGFloat, height: CGFloat, degrees: CGFloat,
              fill: NSColor, details: Bool, base: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    let pivot = NSPoint(x: cx, y: side - (cy + height / 2))
    transform.translateX(by: pivot.x, yBy: pivot.y)
    transform.rotate(byDegrees: -degrees)
    transform.translateX(by: -pivot.x, yBy: -pivot.y)
    transform.concat()

    let card = rounded(cx - width / 2, cy - height / 2, width, height, 46)
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.22)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    fill.setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()

    if details {
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        // Header band, like the app-colored header of a card.
        mix(base, .black, 0.12).setFill()
        rect(cx - width / 2, cy - height / 2, width, 92).fill()
        // A round "app icon" in the header.
        color(0xFFFFFF, 0.92).setFill()
        NSBezierPath(ovalIn: rect(cx + width / 2 - 92, cy - height / 2 + 22, 50, 50)).fill()
        // Lines of text.
        let lineColor = color(0x3A3A3C, 0.22)
        lineColor.setFill()
        let left = cx - width / 2 + 44
        var y = cy - height / 2 + 136
        for fraction in [0.78, 0.62, 0.70, 0.40] as [CGFloat] {
            rounded(left, y, (width - 88) * fraction, 26, 13).fill()
            y += 56
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
}

let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
    let base = color(orange)
    let shape = rounded(100, 100, 824, 824, 185)

    // Shadow under the shape
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.30)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    base.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: one hue, lighter at the top, with a soft highlight
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: mix(base, .white, 0.22), ending: mix(base, .black, 0.08))!
        .draw(in: rect(100, 100, 824, 824), angle: -90)
    NSGradient(starting: color(0xFFFFFF, 0.16), ending: color(0xFFFFFF, 0))!
        .draw(in: rect(100, 100, 824, 300), angle: -90)

    // The fan of cards
    let width: CGFloat = 380, height: CGFloat = 470
    drawCard(cx: 512, cy: 520, width: width, height: height, degrees: -16,
             fill: color(0xFFFFFF, 0.55), details: false, base: base)
    drawCard(cx: 512, cy: 520, width: width, height: height, degrees: 16,
             fill: color(0xFFFFFF, 0.55), details: false, base: base)
    drawCard(cx: 512, cy: 512, width: width, height: height, degrees: 0,
             fill: .white, details: true, base: base)
    NSGraphicsContext.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not draw the icon")
}
try! png.write(to: URL(fileURLWithPath: output))
print("Saved \(output)")
