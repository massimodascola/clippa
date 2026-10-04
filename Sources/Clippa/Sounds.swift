import AppKit
import ClippaCore

/// The short clicks played when something is copied and when Clippa
/// pastes (Settings → General → Play sounds). The built-in ones are
/// synthesized here, so the app ships no sound files; any other sound can
/// be chosen in Settings and is copied into Clippa's data folder.
@MainActor
enum Sounds {
    enum Kind: String, CaseIterable {
        case copy, paste

        /// Preference holding the name of the chosen file, for Settings.
        var nameKey: String { "\(rawValue)SoundName" }
    }

    private static let builtIn: [Kind: NSSound] = [
        .copy: tone(from: 1_250, to: 1_050, duration: 0.11, volume: 0.22),
        .paste: tone(from: 760, to: 620, duration: 0.07, volume: 0.28),
    ].compactMapValues { $0 }
    private static var custom: [Kind: NSSound] = [:]

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: Pref.playSounds)
    }

    static func playCopy() { play(.copy) }
    static func playPaste() { play(.paste) }

    static func play(_ kind: Kind, evenIfOff: Bool = false) {
        guard enabled || evenIfOff, let sound = sound(for: kind) else { return }
        sound.stop()
        sound.play()
    }

    private static var folder: URL {
        ClippaPaths.dataDirectory.appendingPathComponent("Sounds", isDirectory: true)
    }

    /// The chosen file, if any: Sounds/copy.<ext> or Sounds/paste.<ext>.
    private static func customFile(_ kind: Kind) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { ($0 as NSString).deletingPathExtension == kind.rawValue }
            .map { folder.appendingPathComponent($0) }
    }

    private static func sound(for kind: Kind) -> NSSound? {
        if let cached = custom[kind] { return cached }
        if let file = customFile(kind), let sound = NSSound(contentsOf: file, byReference: false) {
            custom[kind] = sound
            return sound
        }
        return builtIn[kind]
    }

    /// Name of the chosen sound, or nil for the built-in one.
    static func customName(_ kind: Kind) -> String? {
        guard customFile(kind) != nil else { return nil }
        return UserDefaults.standard.string(forKey: kind.nameKey) ?? customFile(kind)?.lastPathComponent
    }

    /// Copies a sound file into Clippa's data folder and uses it.
    static func setCustom(_ kind: Kind, from source: URL) throws {
        guard NSSound(contentsOf: source, byReference: true) != nil else {
            throw NSError(domain: "Clippa", code: 2, userInfo: [NSLocalizedDescriptionKey: L("This file is not a sound macOS can play.")])
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = customFile(kind) { try FileManager.default.removeItem(at: old) }
        let ext = source.pathExtension.isEmpty ? "aiff" : source.pathExtension
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("\(kind.rawValue).\(ext)"))
        UserDefaults.standard.set(source.lastPathComponent, forKey: kind.nameKey)
        custom[kind] = nil
    }

    static func useBuiltIn(_ kind: Kind) {
        if let file = customFile(kind) { try? FileManager.default.removeItem(at: file) }
        UserDefaults.standard.removeObject(forKey: kind.nameKey)
        custom[kind] = nil
    }

    /// A sine blip gliding from one pitch to another, with a quick attack
    /// and an exponential fade, as 16-bit mono WAV data.
    private static func tone(from start: Double, to end: Double, duration: Double, volume: Double) -> NSSound? {
        let rate = 44_100.0
        let count = Int(rate * duration)
        var samples = [Int16](repeating: 0, count: count)
        var phase = 0.0
        for index in 0..<count {
            let progress = Double(index) / Double(count)
            let frequency = start + (end - start) * progress
            phase += 2 * Double.pi * frequency / rate
            let attack = min(1, Double(index) / (rate * 0.004))
            let envelope = attack * exp(-5 * progress)
            samples[index] = Int16(sin(phase) * envelope * volume * Double(Int16.max))
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let payload = count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + payload).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)       // PCM, mono
        append(UInt32(rate).littleEndian); append(UInt32(rate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)      // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(UInt32(payload).littleEndian)
        for sample in samples { append(sample.littleEndian) }
        return NSSound(data: data)
    }
}

/// A small message near the bottom of the screen that fades by itself,
/// used when the shelf is already closed (e.g. "press ⌘V to paste").
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        let size = label.intrinsicContentSize
        let width = size.width + 36, height: CGFloat = 38

        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return panel
        }()
        self.panel = panel

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = height / 2
        label.frame = NSRect(x: 18, y: (height - size.height) / 2, width: size.width, height: size.height)
        background.addSubview(label)
        panel.contentView = background

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 80, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
