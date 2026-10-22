import AppKit
import ClippaCore

/// Wispr Flow, the dictation app: it types what you say by pasting it.
enum WisprFlow {
    static let bundleID = "com.electron.wispr-flow"
    /// The app and the helper that writes to the clipboard.
    private static let bundleIDs: Set<String> = [bundleID, "com.electron.wispr-flow.accessibility-mac-app"]

    /// A dictation on its way into an app: marked confidential, with text
    /// and HTML and nothing else, while Wispr Flow is running. Password
    /// managers mark their copies the same way but never add HTML, so a
    /// password is never taken for a dictation.
    static func isDictation(_ types: Set<String>) -> Bool {
        let allowed: Set<String> = [UTI.plainText, UTI.string, UTI.html]
        let content = types.filter { !$0.hasPrefix("org.nspasteboard.") }
        guard types.contains(UTI.concealed), content.contains(UTI.plainText), content.contains(UTI.html),
              content.isSubset(of: allowed) else { return false }
        return NSWorkspace.shared.runningApplications.contains { bundleIDs.contains($0.bundleIdentifier ?? "") }
    }
}
