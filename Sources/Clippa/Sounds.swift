import AppKit

/// The short clicks played when something is copied and when Clippa
/// pastes (Settings → General → Play sounds). They are synthesized here,
/// so the app ships no sound files.
@MainActor
enum Sounds {
    private static let copySound = tone(from: 1_250, to: 1_050, duration: 0.11, volume: 0.22)
    private static let pasteSound = tone(from: 760, to: 620, duration: 0.07, volume: 0.28)

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: Pref.playSounds)
    }

    static func playCopy() {
        guard enabled else { return }
        copySound?.stop()
        copySound?.play()
    }

    static func playPaste() {
        guard enabled else { return }
        pasteSound?.stop()
        pasteSound?.play()
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
