import AppKit

// Draws the Clippa icon (1024x1024) and saves it as a PNG.
// Usage: swift tools/draw-icon.swift <file.png>
//
// A bold white "C" holding a copied card, on a pink-to-violet gradient.
// It follows the macOS icon grid: an 824-point rounded shape centered in a
// 1024 canvas, with a 100-point margin for the shadow.
//
// Centering (study of 4 Oct 2026, measured on the pixels): a C is open on
// one side, so no single center works. With the circle at x = 512 the
// white shape leans left (bounding box center 471, centroid 463); with the
// bounding box at 512 the circle and the card lean right (553 and 601).
// The chosen balance closes the C a little (gap of 2 × 40°) and puts the
// circle and the card at x = 528: bounding box center 499 (−13),
// centroid 490 (−22), circle and card +16, margins 132 and 158.

let side: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let top: UInt32 = 0xF0509A     // pink
let bottom: UInt32 = 0x6D3BE0  // violet
let center = NSPoint(x: 528, y: 512)
let gap: CGFloat = 40          // degrees on each side of the C's opening

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

/// The C and the card inside it.
func drawGlyph() {
    NSGraphicsContext.saveGraphicsState()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: 248, startAngle: gap, endAngle: 360 - gap)
    arc.lineWidth = 96
    arc.lineCapStyle = .round
    shadow(0.25, blur: 24, y: -10)
    NSColor.white.setStroke()
    arc.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The card sits in the middle of the C, slightly tilted.
    let card = NSBezierPath(roundedRect: NSRect(x: -88, y: -110, width: 176, height: 220), xRadius: 30, yRadius: 30)
    let place = NSAffineTransform()
    place.translateX(by: center.x, yBy: center.y)
    place.rotate(byDegrees: -8)

    NSGraphicsContext.saveGraphicsState()
    place.concat()
    shadow(0.28, blur: 20, y: -8)
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
    drawGlyph()
    NSGraphicsContext.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not draw the icon")
}
try! png.write(to: URL(fileURLWithPath: output))
print("Saved \(output)")
