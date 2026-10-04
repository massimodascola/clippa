import Foundation

/// Where Clippa keeps its data, shared by the app and clippa-mcp.
public enum ClippaPaths {
    public static let bundleID = "com.massimodascola.clippa"

    /// ~/Library/Application Support/Clippa (overridable for tests with CLIPPA_DATA_DIR).
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLIPPA_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clippa", isDirectory: true)
    }

    /// The app's preferences. clippa-mcp lives inside Clippa.app, so there
    /// it shares the app's bundle identifier and the standard defaults; run
    /// from anywhere else it reads them through the suite name.
    public static var sharedDefaults: UserDefaults {
        if Bundle.main.bundleIdentifier == bundleID { return .standard }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }

    public static func databaseURL(in directory: URL) -> URL {
        directory.appendingPathComponent("Clippa.sqlite")
    }

    public static func blobsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("Blobs", isDirectory: true)
    }
}

/// Cross-process signal: "the store changed, reload". Used when clippa-mcp
/// writes, and by the app to tell clippa-mcp nothing (one-way is enough).
public enum ClippaSignal {
    public static let storeChanged = "com.massimodascola.clippa.store-changed"

    public static func post(_ name: String = storeChanged) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
