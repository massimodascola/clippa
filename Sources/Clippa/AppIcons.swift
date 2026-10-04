import AppKit

/// Icons and header colors of the apps items were copied from. Like Paste,
/// each card's header takes the main color of its app's icon.
@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: NSColor] = [:]
    private static var names: [String: String] = [:]

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func icon(for bundleID: String?) -> NSImage {
        guard let bundleID else { return genericIcon }
        if let cached = icons[bundleID] { return cached }
        let icon = url(for: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? genericIcon
        icons[bundleID] = icon
        return icon
    }

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        let name = url(for: bundleID).map { FileManager.default.displayName(atPath: $0.path) }?
            .replacingOccurrences(of: ".app", with: "") ?? Pref.knownAppNames[bundleID] ?? bundleID
        names[bundleID] = name
        return name
    }

    private static var genericIcon: NSImage {
        NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// The most saturated common color of the app icon, darkened enough
    /// for white text on top.
    static func color(for bundleID: String?) -> NSColor {
        guard let bundleID else { return .systemGray }
        if let cached = colors[bundleID] { return cached }
        let color = dominantColor(of: icon(for: bundleID)) ?? NSColor(white: 0.45, alpha: 1)
        colors[bundleID] = color
        return color
    }

    private static func dominantColor(of image: NSImage) -> NSColor? {
        let side = 24
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        // Bucket colors by hue and pick the bucket with the most saturated weight.
        var buckets = [Int: (weight: Double, red: Double, green: Double, blue: Double)]()
        var grayTotal = (count: 0.0, brightness: 0.0)
        for x in 0..<side {
            for y in 0..<side {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.6 else { continue }
                let saturation = color.saturationComponent, brightness = color.brightnessComponent
                if saturation < 0.25 || brightness < 0.15 {
                    grayTotal.count += 1
                    grayTotal.brightness += brightness
                    continue
                }
                let key = Int(color.hueComponent * 12) % 12
                let weight = saturation * brightness
                var bucket = buckets[key] ?? (0, 0, 0, 0)
                bucket.weight += weight
                bucket.red += color.redComponent * weight
                bucket.green += color.greenComponent * weight
                bucket.blue += color.blueComponent * weight
                buckets[key] = bucket
            }
        }
        guard let best = buckets.values.max(by: { $0.weight < $1.weight }), best.weight > 2 else {
            // Mostly gray icon (Terminal, Finder sidebar apps...): a neutral header.
            let brightness = grayTotal.count > 0 ? grayTotal.brightness / grayTotal.count : 0.4
            return NSColor(white: min(max(brightness * 0.6, 0.22), 0.45), alpha: 1)
        }
        let color = NSColor(deviceRed: best.red / best.weight, green: best.green / best.weight,
                            blue: best.blue / best.weight, alpha: 1)
        // Keep white text readable.
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(deviceHue: hue, saturation: min(saturation, 0.85), brightness: min(brightness, 0.78), alpha: 1)
    }
}
