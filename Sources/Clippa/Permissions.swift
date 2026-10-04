import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The system permissions Clippa may ask for, and where to grant them.
enum Permissions {
    /// Accessibility ("Device Control and Data Access" on macOS 27): needed
    /// to paste straight into the app you are using and for Paste Stack.
    static var canPaste: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt (once) and opens the right Settings pane.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings("Privacy_Accessibility")
        }
    }

    /// macOS 15.4 and later ask before an app reads the clipboard by itself.
    /// Clippa needs "Always Allow".
    enum ClipboardAccess {
        case allowed, denied, notAskedYet, unknown
    }

    static var clipboardAccess: ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        case .ask: return .notAskedYet
        case .default: return .notAskedYet
        @unknown default: return .unknown
        }
    }

    static func openClipboardAccessSettings() {
        openSettings("Privacy_Pasteboard")
    }

    /// Screen Recording: only for the optional "use what's on screen" part
    /// of suggestions.
    static var canReadScreen: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess() {
            openSettings("Privacy_ScreenCapture")
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
