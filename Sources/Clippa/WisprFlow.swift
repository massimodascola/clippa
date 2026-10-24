import AppKit
import ClippaCore

/// Wispr Flow, the dictation app. It types a dictation by putting it on the
/// clipboard (marked confidential), pasting it, and putting the old
/// clipboard back once the text has landed. If nothing takes the paste (no
/// text box), it leaves the dictation on the clipboard for you to paste.
///
/// Clippa never reads that clipboard: reading it would tell Wispr Flow the
/// paste worked, and it would put the old clipboard back. It takes the
/// dictation from Wispr Flow's own history on this Mac instead. A password
/// copied from a password manager is marked the same way, and is never read.
enum WisprFlow {
    static let bundleID = "com.electron.wispr-flow"
    /// The app and the helper that writes to the clipboard.
    private static let bundleIDs: Set<String> = [bundleID, "com.electron.wispr-flow.accessibility-mac-app"]

    /// A confidential text copy while Wispr Flow is running: maybe a dictation.
    static func mightBeDictation(_ types: Set<String>) -> Bool {
        guard types.contains(UTI.concealed), types.contains(UTI.plainText) || types.contains(UTI.string) else { return false }
        return NSWorkspace.shared.runningApplications.contains { bundleIDs.contains($0.bundleIdentifier ?? "") }
    }

    /// Wispr Flow's history database (overridable for tests).
    static var historyURL: URL {
        if ProcessInfo.processInfo.environment["CLIPPA_DEBUG_HOOKS"] != nil,
           let path = ProcessInfo.processInfo.environment["CLIPPA_WISPR_HISTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wispr Flow/flow.sqlite")
    }

    struct Dictation: Sendable {
        /// When the dictation started, as Wispr Flow writes it (UTC).
        var timestamp: String
        var text: String
        /// False while Wispr Flow has not recorded what it pasted yet.
        var isFinal: Bool
    }

    /// Wispr Flow writes its times as "2026-10-24 16:42:26.082 +00:00".
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date) + " +00:00"
    }

    /// Dictations started after `after` and not before `notBefore`, oldest
    /// first. Read-only; nil if the history cannot be read (Wispr Flow
    /// changed its format, or keeps no history).
    static func dictations(after: String, notBefore: String) -> [Dictation]? {
        do {
            let database = try SQLiteDatabase(path: historyURL.path, readOnly: true)
            return try database.query("""
                SELECT timestamp, pastedText, formattedText FROM History
                WHERE timestamp > ? AND timestamp >= ? AND isArchived = 0
                ORDER BY timestamp LIMIT 10
                """, [after, notBefore]) { row -> Dictation? in
                let pasted = row.optionalString(1) ?? ""
                let formatted = row.optionalString(2) ?? ""
                let text = pasted.isEmpty ? formatted : pasted
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return Dictation(timestamp: row.string(0), text: text, isFinal: !pasted.isEmpty)
            }.compactMap { $0 }
        } catch {
            return nil
        }
    }
}
