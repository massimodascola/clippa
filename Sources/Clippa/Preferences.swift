import AppKit
import ClippaCore

/// Where a chosen item goes: straight into the app you were using (needs
/// Accessibility), or only onto the clipboard.
enum PasteDestination: String, CaseIterable {
    case activeApp
    case clipboard
}

/// Modifier keys that Quick Paste and plain text mode can use.
enum ModifierChoice: String, CaseIterable {
    case command, shift, option, control

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
}

/// Every setting, with its key in UserDefaults. SwiftUI views bind to the
/// same keys with @AppStorage.
enum Pref {
    static let keepHistory = "keepHistory"
    static let pasteDestination = "pasteDestination"
    static let alwaysPlainText = "alwaysPlainText"
    static let ignoreConfidential = "ignoreConfidential"
    static let ignoreTransient = "ignoreTransient"
    static let ignoredApps = "ignoredApps"
    static let fetchLinkPreviews = "fetchLinkPreviews"
    static let recognizeText = "recognizeText"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let playSounds = "playSounds"
    static let activateShortcut = "activateShortcut"
    static let stackShortcut = "stackShortcut"
    static let quickPasteModifier = "quickPasteModifier"
    static let plainTextModifier = "plainTextModifier"
    static let panelHeight = "panelHeight"
    static let suggestionsEnabled = "suggestionsEnabled"
    static let useScreenContent = "useScreenContent"
    static let mcpEnabled = "mcpEnabled"
    static let mcpAllowChanges = "mcpAllowChanges"
    static let syncMode = "syncMode"
    static let syncFolder = "syncFolder"
    static let deviceID = "deviceID"
    static let onboardingDone = "onboardingDone"
    static let pausedUntil = "pausedUntil"
    static let stackDirectionReversed = "stackDirectionReversed"

    /// Password managers and similar apps ignored out of the box.
    static let defaultIgnoredApps = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal",
        "com.nordpass.safari.app.password.manager",
    ]

    /// Names to show for the apps above when they are not installed.
    static let knownAppNames = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "com.lastpass.LastPass": "LastPass",
        "org.keepassxc.keepassxc": "KeePassXC",
        "com.dashlane.dashlanephonefinal": "Dashlane",
        "com.nordpass.safari.app.password.manager": "NordPass",
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            keepHistory: HistoryRetention.default.rawValue,
            pasteDestination: PasteDestination.activeApp.rawValue,
            alwaysPlainText: false,
            ignoreConfidential: true,
            ignoreTransient: true,
            ignoredApps: defaultIgnoredApps,
            fetchLinkPreviews: true,
            recognizeText: true,
            showMenuBarIcon: true,
            playSounds: false,
            quickPasteModifier: ModifierChoice.command.rawValue,
            plainTextModifier: ModifierChoice.shift.rawValue,
            panelHeight: 330.0,
            suggestionsEnabled: true,
            useScreenContent: false,
            mcpEnabled: false,
            mcpAllowChanges: false,
            syncMode: JournalMode.off.rawValue,
            onboardingDone: false,
            stackDirectionReversed: false,
        ])
    }

    private static var defaults: UserDefaults { .standard }

    static var keepHistoryValue: HistoryRetention {
        HistoryRetention(rawValue: defaults.string(forKey: keepHistory) ?? "") ?? .default
    }

    static var destination: PasteDestination {
        PasteDestination(rawValue: defaults.string(forKey: pasteDestination) ?? "") ?? .activeApp
    }

    static var quickPasteFlags: NSEvent.ModifierFlags {
        (ModifierChoice(rawValue: defaults.string(forKey: quickPasteModifier) ?? "") ?? .command).flags
    }

    static var plainTextFlags: NSEvent.ModifierFlags {
        (ModifierChoice(rawValue: defaults.string(forKey: plainTextModifier) ?? "") ?? .shift).flags
    }

    static var syncModeValue: JournalMode {
        JournalMode(rawValue: defaults.string(forKey: syncMode) ?? "") ?? .off
    }

    static var ignoredAppIDs: [String] {
        defaults.stringArray(forKey: ignoredApps) ?? []
    }

    /// A stable id for this Mac, used to tell devices apart in sync and
    /// in the "device" filter.
    static var thisDeviceID: String {
        if let id = defaults.string(forKey: deviceID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceID)
        return id
    }

    static var thisDeviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    /// iCloud Drive/Clippa, unless the user picked another folder.
    static var syncFolderURL: URL {
        if let path = defaults.string(forKey: syncFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Clippa", isDirectory: true)
    }

    static var pausedUntilDate: Date? {
        get { defaults.object(forKey: pausedUntil) as? Date }
        set { defaults.set(newValue, forKey: pausedUntil) }
    }
}

/// Localized string for AppKit code. SwiftUI Text looks keys up by itself.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string, e.g. L("%lld items", count).
/// Plural forms come from Localizable.stringsdict.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    withVaList(arguments) { NSString(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: $0) as String }
}
