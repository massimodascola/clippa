import AppKit

// Draws the Clippa icon (1024x1024) and saves it as a PNG.
// Usage: swift tools/draw-icon.swift <file.png>
//
// ⌘C in white inside a keyboard key with a pink-to-violet outline, on
// graphite. The ⌘ sign and the C are drawn as paths: no Apple font, whose
// license does not allow logos. It follows the macOS icon grid: an
// 824-point rounded shape centered in a 1024 canvas, with a 100-point
// margin for the shadow.
//
// Centering: the key is centered on the canvas (x 214 to 810). The C is
// open on the right, so the ⌘C group is drawn once off screen, measured on
// its pixels and moved until its outline sits in the middle of the key;
// the script prints the measures.

let side: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let pink: UInt32 = 0xF0509A
let violet: UInt32 = 0x6D3BE0
let keyRect = NSRect(x: 214, y: 284, width: 596, height: 456)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The ⌘ sign: a square whose sides run on into four loops.
func commandSign(center c: NSPoint, size: CGFloat, width: CGFloat) -> NSBezierPath {
    let a = size * 0.20, r = size * 0.15
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    for x in [-a, a] {
        path.move(to: NSPoint(x: c.x + x, y: c.y - a - r))
        path.line(to: NSPoint(x: c.x + x, y: c.y + a + r))
    }
    for y in [-a, a] {
        path.move(to: NSPoint(x: c.x - a - r, y: c.y + y))
        path.line(to: NSPoint(x: c.x + a + r, y: c.y + y))
    }
    // Each loop leaves out the quarter facing the middle.
    for (sx, sy, start) in [(1.0, 1.0, 270.0), (-1.0, 1.0, 0.0), (-1.0, -1.0, 90.0), (1.0, -1.0, 180.0)]
        as [(CGFloat, CGFloat, CGFloat)] {
        let loop = NSPoint(x: c.x + sx * (a + r), y: c.y + sy * (a + r))
        path.move(to: NSPoint(x: loop.x + r * cos(start * .pi / 180), y: loop.y + r * sin(start * .pi / 180)))
        path.appendArc(withCenter: loop, radius: r, startAngle: start, endAngle: start + 270)
    }
    return path
}

/// A geometric C, open on the right.
func letterC(center c: NSPoint, radius: CGFloat, width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.appendArc(withCenter: c, radius: radius, startAngle: 46, endAngle: 314)
    path.lineWidth = width
    path.lineCapStyle = .round
    return path
}

/// ⌘ and C side by side, moved by `dx`.
func drawGlyphs(dx: CGFloat) {
    NSColor.white.setStroke()
    commandSign(center: NSPoint(x: 380 + dx, y: 512), size: 210, width: 28).stroke()
    letterC(center: NSPoint(x: 646 + dx, y: 512), radius: 86, width: 42).stroke()
}

/// Left and right edges of the glyphs, measured on a bitmap.
func glyphEdges(dx: CGFloat) -> (left: CGFloat, right: CGFloat) {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawGlyphs(dx: dx)
    NSGraphicsContext.restoreGraphicsState()
    var left = Int(side), right = 0
    for y in stride(from: 380, to: 644, by: 2) {
        for x in 0..<Int(side) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            left = min(left, x)
            right = max(right, x + 1)
        }
    }
    return (CGFloat(left), CGFloat(right))
}

let measured = glyphEdges(dx: 0)
let dx = (keyRect.midX - (measured.left + measured.right) / 2).rounded()
let final = glyphEdges(dx: dx)
let inner = keyRect.insetBy(dx: 20, dy: 20)
print("⌘C before: \(measured.left)–\(measured.right), center \((measured.left + measured.right) / 2)")
print("moved by \(dx): \(final.left)–\(final.right), center \((final.left + final.right) / 2) (key center \(keyRect.midX))")
print("space inside the key: left \(final.left - inner.minX), right \(inner.maxX - final.right)")

let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
    let shape = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

    // Shadow under the shape
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.30)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x15131F).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Graphite background with a soft highlight at the top
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: color(0x2B2840), ending: color(0x15131F))!.draw(in: shape.bounds, angle: -90)
    NSGradient(starting: color(0xFFFFFF, 0.12), ending: color(0xFFFFFF, 0))!
        .draw(in: NSRect(x: 100, y: 604, width: 824, height: 320), angle: -90)

    // The key: a glowing pink-to-violet outline around a dark face
    let key = NSBezierPath(roundedRect: keyRect, xRadius: 96, yRadius: 96)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(pink, 0.8)
    glow.shadowBlurRadius = 40
    glow.set()
    NSGradient(starting: color(pink), ending: color(violet))!.draw(in: key, angle: -60)
    NSGraphicsContext.restoreGraphicsState()
    color(0x1C1A29).setFill()
    NSBezierPath(roundedRect: inner, xRadius: 78, yRadius: 78).fill()

    drawGlyphs(dx: dx)
    NSGraphicsContext.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not draw the icon")
}
try! png.write(to: URL(fileURLWithPath: output))
print("Saved \(output)")
