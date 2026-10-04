import AppKit

// Clippa: a clipboard manager for macOS. Everything you copy, kept for as
// long as you choose, a keystroke away (Shift-Command-V).
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.setActivationPolicy(.accessory)
    application.run()
}
