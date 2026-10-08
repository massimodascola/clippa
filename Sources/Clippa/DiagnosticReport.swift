import AppKit
import ClippaCore
import Security

/// "Report a Problem…": a text file the user can send to the developer.
/// It describes the Mac, Clippa's settings and permissions, the size of the
/// data, the recent log and recent crash reports. It never contains what
/// was copied.
@MainActor
enum DiagnosticReport {
    static let issuesURL = URL(string: "https://github.com/massimodascola/clippa/issues/new")!
    private static let crashFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    /// Creates the report, saves it on the Desktop and tells the user what to do with it.
    static func createAndShow(app: AppController) {
        let text = build(app: app)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "Clippa Report \(formatter.string(from: Date())).txt"
        let manager = FileManager.default
        let folders = [manager.urls(for: .desktopDirectory, in: .userDomainMask).first,
                       manager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                       manager.temporaryDirectory].compactMap { $0 }
        var saved: URL?
        for folder in folders {
            let url = folder.appendingPathComponent(name)
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                saved = url
                break
            }
        }
        guard let saved else {
            Log.error("Could not save the diagnostic report anywhere")
            return
        }
        Log.info("Diagnostic report created")
        NSWorkspace.shared.activateFileViewerSelecting([saved])

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Diagnostic report created")
        alert.informativeText = L("“%@” is in %@. Send it to the developer, for example by attaching it to a GitHub issue.\n\nIt contains Clippa's settings, its log and any recent crash reports, but nothing you copied.",
                                  name, saved.deletingLastPathComponent().lastPathComponent)
        alert.addButton(withTitle: L("Done"))
        alert.addButton(withTitle: L("Report on GitHub"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(issuesURL)
        }
    }

    /// At launch: if Clippa crashed since the last check, offer a report.
    static func checkForRecentCrash(app: AppController) {
        let key = "lastCrashCheck"
        let defaults = UserDefaults.standard
        let since = defaults.object(forKey: key) as? Date
        defaults.set(Date(), forKey: key)
        guard let since else { return } // first launch: old reports are not ours to show
        let crashes = crashReports(since: since)
        guard let latest = crashes.first else { return }
        Log.warning("Clippa closed unexpectedly since the last launch: \(latest.lastPathComponent)")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Clippa quit unexpectedly")
        alert.informativeText = L("A diagnostic report helps fix it. It contains nothing you copied.")
        alert.addButton(withTitle: L("Create Report"))
        alert.addButton(withTitle: L("Not Now"))
        if alert.runModal() == .alertFirstButtonReturn {
            createAndShow(app: app)
        }
    }

    /// Crash reports of Clippa and clippa-mcp, newest first.
    static func crashReports(since: Date) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: crashFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { url in
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("clippa"), url.pathExtension == "ips" || url.pathExtension == "crash" else { return false }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return date > since
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }

    // MARK: - Content

    static func build(app: AppController) -> String {
        var out = "Clippa diagnostic report\n"
        out += "Created: \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "It contains no clipboard content: no copied text, images, links or file names.\n"

        section(&out, "App")
        let info = Bundle.main.infoDictionary ?? [:]
        line(&out, "Version", "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        line(&out, "Installed in", Bundle.main.bundleURL.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        line(&out, "Signature", signature())
        line(&out, "Running since", ISO8601DateFormatter().string(from: app.launchDate))

        section(&out, "Mac")
        line(&out, "macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        line(&out, "Model", sysctl("hw.model") ?? "?")
        #if arch(arm64)
        line(&out, "Processor", "Apple Silicon (arm64)")
        #else
        line(&out, "Processor", "Intel (x86_64)")
        #endif
        line(&out, "Memory", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
        line(&out, "Languages", Locale.preferredLanguages.prefix(3).joined(separator: ", "))
        line(&out, "Screens", NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\(Int($0.backingScaleFactor))x" }
            .joined(separator: ", "))
        line(&out, "Developer tools", developerTools())

        section(&out, "Permissions")
        line(&out, "Accessibility (paste, Paste Stack, hold ⌘V)", Permissions.canPaste ? "allowed" : "NOT allowed")
        line(&out, "Clipboard access", "\(Permissions.clipboardAccess)")
        line(&out, "Screen Recording (optional)", Permissions.canReadScreen ? "allowed" : "not allowed")
        line(&out, "Open Clippa shortcut", app.activateShortcutWorks ? "registered" : "REFUSED by macOS")
        line(&out, "Paste Stack shortcut", app.stackShortcutWorks ? "registered" : "REFUSED by macOS")
        line(&out, "Hold ⌘V watcher", app.holdCommandV.isRunning ? "running" : "not running")
        line(&out, "Paste Stack", app.stack.isActive ? "on" : "off")
        line(&out, "Paused", app.isPaused ? "yes" : "no")

        section(&out, "Settings")
        let defaults = UserDefaults.standard
        for key in [Pref.keepHistory, Pref.pasteDestination, Pref.alwaysPlainText, Pref.ignoreConfidential,
                    Pref.ignoreTransient, Pref.fetchLinkPreviews, Pref.recognizeText, Pref.showMenuBarIcon,
                    Pref.playSounds, Pref.quickPasteModifier, Pref.plainTextModifier, Pref.panelHeight,
                    Pref.suggestionsEnabled, Pref.useScreenContent, Pref.mcpEnabled, Pref.mcpAllowChanges,
                    Pref.syncMode, Pref.holdCommandV, Pref.onboardingDone] {
            line(&out, key, "\(defaults.object(forKey: key) ?? "?")")
        }
        line(&out, "ignoredApps", "\(Pref.ignoredAppIDs.count) apps")
        line(&out, "activateShortcut", Shortcut.load(Pref.activateShortcut, default: .activateDefault)?.displayString ?? "none")
        line(&out, "stackShortcut", Shortcut.load(Pref.stackShortcut, default: .stackDefault)?.displayString ?? "none")
        line(&out, "custom sounds", Sounds.Kind.allCases.map { "\($0.rawValue) \(Sounds.customName($0) == nil ? "built-in" : "custom")" }
            .joined(separator: ", "))
        line(&out, "syncFolder", (defaults.string(forKey: Pref.syncFolder) ?? "").isEmpty ? "iCloud Drive (default)" : "custom folder")

        section(&out, "Data")
        let store = app.store!
        let db = store.db
        line(&out, "Items", "\(Log.attempt("report: count items") { try store.totalItemCount() } ?? -1)")
        for kind in ItemKind.allCases {
            line(&out, "  \(kind.rawValue)", "\(Log.attempt("report: count \(kind.rawValue)") { try db.scalarInt("SELECT COUNT(*) FROM items WHERE kind = ?", [kind.rawValue]) } ?? -1)")
        }
        line(&out, "  pinned", "\(Log.attempt("report: count pinned") { try db.scalarInt("SELECT COUNT(*) FROM items WHERE pinboard_id IS NOT NULL") } ?? -1)")
        line(&out, "Pinboards", "\(Log.attempt("report: count pinboards") { try store.pinboards().count } ?? -1)")
        let dbSize = (try? FileManager.default.attributesOfItem(atPath: ClippaPaths.databaseURL(in: store.directory).path))?[.size] as? Int64 ?? 0
        line(&out, "Database size", ByteCountFormatter.string(fromByteCount: dbSize, countStyle: .file))
        line(&out, "Files size", ByteCountFormatter.string(fromByteCount: Int64(store.blobs.totalSize()), countStyle: .file))
        line(&out, "Schema version", "\(Log.attempt("report: schema") { try db.scalarInt("PRAGMA user_version") } ?? -1)")
        let sqlite: String? = Log.attempt("report: sqlite version") { try db.scalarString("SELECT sqlite_version()") } ?? nil
        line(&out, "SQLite", sqlite ?? "?")
        let integrity: String? = Log.attempt("report: integrity") { try db.scalarString("PRAGMA quick_check") } ?? nil
        line(&out, "Integrity check", integrity ?? "?")
        line(&out, "Sync outbox", "\(Log.attempt("report: outbox") { try db.scalarInt("SELECT COUNT(*) FROM outbox") } ?? -1) changes waiting")

        section(&out, "Sync")
        line(&out, "Mode", Pref.syncModeValue.rawValue)
        line(&out, "Last sync", app.sync.lastSync.map { ISO8601DateFormatter().string(from: $0) } ?? "never")
        line(&out, "Last error", app.sync.lastError ?? "none")
        line(&out, "Other Macs", "\(app.sync.otherDevices.count)")

        section(&out, "Recent log")
        let lines = Log.recentLines(400)
        out += lines.isEmpty ? "(empty)\n" : lines.joined(separator: "\n") + "\n"

        section(&out, "Crash reports (last 30 days)")
        let crashes = crashReports(since: Date().addingTimeInterval(-30 * 86_400))
        if crashes.isEmpty {
            out += "none\n"
        } else {
            for url in crashes { out += "- \(url.lastPathComponent)\n" }
            for url in crashes.prefix(3) {
                out += "\n----- \(url.lastPathComponent) -----\n"
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? "(unreadable)"
                out += String(content.prefix(80_000)) + "\n"
            }
        }
        return out
    }

    private static func section(_ out: inout String, _ title: String) {
        out += "\n== \(title) ==\n"
    }

    private static func line(_ out: inout String, _ key: String, _ value: String) {
        out += "\(key): \(value)\n"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Ad hoc, the local certificate, or another one: it decides whether
    /// macOS keeps the Accessibility permission across updates.
    private static func signature() -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else {
            return "unknown"
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return "unknown" }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if flags & UInt32(SecCodeSignatureFlags.adhoc.rawValue) != 0 { return "ad hoc (permissions reset on every update)" }
        if let certificate = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
           let summary = SecCertificateCopySubjectSummary(certificate) as String? {
            return summary
        }
        return "signed"
    }

    private static func developerTools() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "not found" }
        process.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "not found" : path
    }
}
