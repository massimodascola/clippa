import AppKit
import ClippaCore
import Combine
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, shortcuts, privacy, sync, intelligence, about

    var title: String {
        switch self {
        case .general: return L("General")
        case .shortcuts: return L("Shortcuts")
        case .privacy: return L("Privacy")
        case .sync: return L("Sync")
        case .intelligence: return L("Intelligence")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .privacy: return "hand.raised"
        case .sync: return "arrow.triangle.2.circlepath.icloud"
        case .intelligence: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

/// Settings, with the classic toolbar of tabs.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()
    private unowned let app: AppController

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: AnyView(view(for: tab).frame(width: 620)))
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.title = L("Clippa Settings")
    }

    required init?(coder: NSCoder) { fatalError() }

    @ViewBuilder
    private func view(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings(app: app)
        case .shortcuts: ShortcutSettings(app: app)
        case .privacy: PrivacySettings()
        case .sync: SyncSettings(sync: app.sync)
        case .intelligence: IntelligenceSettings()
        case .about: AboutSettings(store: app.store)
        }
    }

    func show(tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - General

struct GeneralSettings: View {
    let app: AppController
    @AppStorage(Pref.keepHistory) private var keepHistory = HistoryRetention.default.rawValue
    @AppStorage(Pref.pasteDestination) private var destination = PasteDestination.activeApp.rawValue
    @AppStorage(Pref.alwaysPlainText) private var alwaysPlainText = false
    @AppStorage(Pref.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Pref.playSounds) private var playSounds = false
    @State private var openAtLogin = false
    @State private var canPaste = Permissions.canPaste
    @State private var clipboardAccess = Permissions.clipboardAccess
    @State private var stats = ""
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle(L("Open Clippa at login"), isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, value in
                        if value != app.opensAtLogin, let error = app.setOpenAtLogin(value) {
                            openAtLogin = app.opensAtLogin
                            NSAlert(error: NSError(domain: "Clippa", code: 1, userInfo: [NSLocalizedDescriptionKey: error])).runModal()
                        }
                    }
                Toggle(L("Show Clippa in the menu bar"), isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, _ in app.updateStatusItem() }
            }
            Section {
                Picker(L("Keep history"), selection: Binding(get: { keepHistory }, set: { changeRetention(to: $0) })) {
                    ForEach(HistoryRetention.allCases, id: \.rawValue) { retention in
                        Text(retention.name).tag(retention.rawValue)
                    }
                }
                Text(L("Older items are deleted automatically. Pinned items and items you chose to keep stay. Each item can have its own rule: right-click it and choose Keep."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(stats).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Erase History…")) { eraseHistory() }
                }
            }
            Section {
                Picker(L("Paste items"), selection: $destination) {
                    Text(L("To the active app")).tag(PasteDestination.activeApp.rawValue)
                    Text(L("To the clipboard only")).tag(PasteDestination.clipboard.rawValue)
                }
                if destination == PasteDestination.activeApp.rawValue {
                    PermissionRow(granted: canPaste,
                                  title: L("Accessibility"),
                                  detail: L("Lets Clippa press ⌘V in the app you are using. Nothing else. If Clippa is already switched on in that list but this still shows a warning, remove it with − and switch it on again."),
                                  action: Permissions.requestAccessibility)
                }
                Toggle(L("Always paste as plain text"), isOn: $alwaysPlainText)
                Toggle(L("Play sounds"), isOn: $playSounds)
            }
            if #available(macOS 15.4, *) {
                Section {
                    PermissionRow(granted: clipboardAccess == .allowed,
                                  title: L("Clipboard access"),
                                  detail: L("macOS asks before an app reads the clipboard by itself. Choose “Always Allow” for Clippa in Privacy & Security → Paste from Other Apps."),
                                  action: Permissions.openClipboardAccessSettings)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: update)
        .onReceive(refresh) { _ in update() }
    }

    private func update() {
        openAtLogin = app.opensAtLogin
        canPaste = Permissions.canPaste
        clipboardAccess = Permissions.clipboardAccess
        let count = (try? app.store.totalItemCount()) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(app.store.blobs.totalSize()), countStyle: .file)
        stats = L("%lld items", count) + ", " + size
    }

    private func changeRetention(to raw: String) {
        guard let retention = HistoryRetention(rawValue: raw) else { return }
        let count = (try? app.store.countExpiring(under: retention)) ?? 0
        if count > 0 {
            let alert = NSAlert()
            alert.messageText = L("Delete %lld older items?", count)
            alert.informativeText = L("They are older than %@. Pinned items are not deleted. This can't be undone.", retention.name.lowercased())
            alert.addButton(withTitle: L("Delete and Apply"))
            alert.addButton(withTitle: L("Cancel"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        keepHistory = raw
        app.runHousekeeping()
        update()
    }

    private func eraseHistory() {
        let alert = NSAlert()
        alert.messageText = L("Erase the clipboard history?")
        alert.informativeText = L("Pinned items and items you chose to keep forever stay. This can't be undone.")
        alert.addButton(withTitle: L("Erase"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = try? app.store.eraseHistory()
        _ = try? app.store.collectGarbage()
        app.storeDidChange()
        app.shelf.externalChange()
        update()
    }
}

struct PermissionRow: View {
    let granted: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(L("Open Settings…"), action: action)
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    let app: AppController
    @AppStorage(Pref.quickPasteModifier) private var quickModifier = ModifierChoice.command.rawValue
    @AppStorage(Pref.plainTextModifier) private var plainModifier = ModifierChoice.shift.rawValue
    @State private var activate = Shortcut.load(Pref.activateShortcut, default: .activateDefault)
    @State private var stack = Shortcut.load(Pref.stackShortcut, default: .stackDefault)
    @State private var shortcutsWork = true

    private func refresh() {
        shortcutsWork = app.activateShortcutWorks && app.stackShortcutWorks
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Open Clippa")) {
                    ShortcutRecorder(shortcut: $activate) { value in
                        Shortcut.save(value, key: Pref.activateShortcut)
                        app.registerHotKeys()
                        refresh()
                    }
                }
                LabeledContent(L("Paste Stack")) {
                    ShortcutRecorder(shortcut: $stack) { value in
                        Shortcut.save(value, key: Pref.stackShortcut)
                        app.registerHotKeys()
                        refresh()
                    }
                }
                if !shortcutsWork {
                    Text(L("Another app is already using one of these shortcuts. Quit that app or choose a different shortcut."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker(L("Quick Paste (1–9)"), selection: $quickModifier) {
                    ForEach(ModifierChoice.allCases, id: \.rawValue) { Text("\($0.symbol) 1…9").tag($0.rawValue) }
                }
                Picker(L("Plain text mode"), selection: $plainModifier) {
                    ForEach(ModifierChoice.allCases, id: \.rawValue) { Text("\($0.symbol) ↩").tag($0.rawValue) }
                }
                HStack {
                    Spacer()
                    Button(L("Restore Defaults")) {
                        activate = .activateDefault
                        stack = .stackDefault
                        Shortcut.save(.activateDefault, key: Pref.activateShortcut)
                        Shortcut.save(.stackDefault, key: Pref.stackShortcut)
                        quickModifier = ModifierChoice.command.rawValue
                        plainModifier = ModifierChoice.shift.rawValue
                        app.registerHotKeys()
                        refresh()
                    }
                }
            }
            .onAppear(perform: refresh)
            Section(L("In the shelf")) {
                shortcutRow("← →", L("Select previous or next item"))
                shortcutRow("⇧← ⇧→", L("Extend the selection"))
                shortcutRow("↩ / ⇧↩", L("Paste / paste as plain text"))
                shortcutRow("⌘1…9", L("Quick Paste"))
                shortcutRow("Space", L("Preview"))
                shortcutRow("⌘C", L("Copy to the clipboard"))
                shortcutRow("⌘E / ⌘R", L("Edit / rename"))
                shortcutRow("⌘N / ⇧⌘N", L("New text item / new pinboard"))
                shortcutRow("⌘F", L("Search"))
                shortcutRow("⌘← ⌘→", L("Previous or next pinboard"))
                shortcutRow("⌘G", L("Show a search result in its list"))
                shortcutRow("⌫ / ⌘Z", L("Delete / undo"))
                shortcutRow("⌘O", L("Open link or file"))
                shortcutRow("⌘T", L("Pause for 1 hour"))
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ keys: String, _ text: String) -> some View {
        LabeledContent(text) {
            Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

/// Click, then press the new shortcut. Escape cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Type shortcut…") : (shortcut?.displayString ?? L("None")))
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case 53: // Escape
                stop()
            case 51, 117: // Delete
                shortcut = nil
                onChange(nil)
                stop()
            default:
                guard !flags.intersection([.command, .option, .control]).isEmpty else {
                    NSSound.beep()
                    return nil
                }
                let value = Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue)
                shortcut = value
                onChange(value)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @AppStorage(Pref.ignoreConfidential) private var ignoreConfidential = true
    @AppStorage(Pref.ignoreTransient) private var ignoreTransient = true
    @AppStorage(Pref.fetchLinkPreviews) private var fetchLinkPreviews = true
    @AppStorage(Pref.recognizeText) private var recognizeText = true
    @State private var apps: [String] = Pref.ignoredAppIDs
    @State private var selectedApp: String?

    var body: some View {
        Form {
            Section {
                Toggle(L("Ignore confidential content"), isOn: $ignoreConfidential)
                Text(L("Do not save passwords and sensitive data when detected.")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("Ignore transient content"), isOn: $ignoreTransient)
                Text(L("Do not save temporary data generated by other apps.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Ignore applications")) {
                Text(L("Do not save content copied from the applications below.")).font(.caption).foregroundStyle(.secondary)
                List(selection: $selectedApp) {
                    ForEach(apps, id: \.self) { id in
                        HStack {
                            Image(nsImage: AppIcons.icon(for: id)).resizable().frame(width: 18, height: 18)
                            Text(AppIcons.name(for: id))
                            Spacer()
                            Text(id).font(.caption).foregroundStyle(.tertiary)
                        }
                        .tag(id)
                    }
                }
                .frame(minHeight: 130)
                HStack(spacing: 6) {
                    Button { addApp() } label: { Image(systemName: "plus") }
                    Button {
                        if let selectedApp { apps.removeAll { $0 == selectedApp } }
                        save()
                    } label: { Image(systemName: "minus") }
                        .disabled(selectedApp == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
            }
            Section {
                Toggle(L("Show link previews"), isOn: $fetchLinkPreviews)
                Text(L("Clippa downloads the title and picture of copied web links.")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("Recognize text in images"), isOn: $recognizeText)
                Text(L("Done on this Mac, so you can search for words inside screenshots.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) { apps.append(id) }
        }
        save()
    }

    private func save() {
        UserDefaults.standard.set(apps, forKey: Pref.ignoredApps)
    }
}

// MARK: - Sync

struct SyncSettings: View {
    let sync: SyncCoordinator
    @AppStorage(Pref.syncMode) private var mode = JournalMode.off.rawValue
    @AppStorage(Pref.syncFolder) private var folder = ""

    var body: some View {
        Form {
            Section {
                Picker(L("Sync with your other Macs"), selection: $mode) {
                    Text(L("Off")).tag(JournalMode.off.rawValue)
                    Text(L("Pinboards only")).tag(JournalMode.pinboardsOnly.rawValue)
                    Text(L("Clipboard history and pinboards")).tag(JournalMode.everything.rawValue)
                }
                .onChange(of: mode) { _, _ in sync.configure() }
                Text(L("Clippa syncs through a folder in your iCloud Drive: no server, nothing sent to anyone else. Each Mac has its own setting. On a work Mac with a personal iCloud account, choose “Pinboards only” or leave sync off, so work content stays on that Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Folder")) {
                LabeledContent(L("Location")) {
                    Text(Pref.syncFolderURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Choose…")) { chooseFolder() }
                    if !folder.isEmpty { Button(L("Use iCloud Drive")) { folder = ""; sync.configure() } }
                    Spacer()
                    Button(L("Show in Finder")) {
                        try? FileManager.default.createDirectory(at: Pref.syncFolderURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Pref.syncFolderURL)
                    }
                }
                Text(L("Any synced folder works (iCloud Drive, Dropbox, a shared drive). Use the same folder on every Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if mode != JournalMode.off.rawValue {
                Section(L("Status")) {
                    LabeledContent(L("Last sync")) {
                        if sync.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(sync.lastSync.map { $0.formatted(date: .omitted, time: .standard) } ?? L("Never"))
                        }
                    }
                    LabeledContent(L("Other Macs")) {
                        Text(sync.otherDevices.isEmpty ? L("None yet") : sync.otherDevices.joined(separator: ", "))
                    }
                    if sync.waitingForFiles {
                        Text(L("Waiting for iCloud Drive to download some files.")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = sync.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button(L("Sync Now")) { sync.syncNow() }
                        Spacer()
                    }
                }
            } else {
                Section {
                    Button(L("Remove This Mac's Data from the Sync Folder")) { sync.removeThisMacFromFolder() }
                    Text(L("The other Macs keep what they already received.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
        sync.configure()
    }
}

// MARK: - Intelligence

struct IntelligenceSettings: View {
    @AppStorage(Pref.suggestionsEnabled) private var suggestions = true
    @AppStorage(Pref.useScreenContent) private var useScreen = false
    @AppStorage(Pref.mcpEnabled) private var mcpEnabled = false
    @AppStorage(Pref.mcpAllowChanges) private var mcpAllowChanges = false
    @State private var copied: String?

    private var mcpPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clippa-mcp").path
    }

    private var claudeCodeCommand: String {
        "claude mcp add --scope user clippa -- \"\(mcpPath)\""
    }

    private var desktopConfig: String {
        """
        "clippa": {
          "command": "\(mcpPath)"
        }
        """
    }

    var body: some View {
        Form {
            Section(L("Suggestions")) {
                Toggle(L("Suggest items for the app you are using"), isOn: $suggestions)
                Text(SuggestionEngine.modelAvailable
                     ? L("The ✦ button in the shelf shows the items that fit what you are doing, ranked on this Mac with Apple Intelligence.")
                     : L("The ✦ button in the shelf shows the items that fit what you are doing. With Apple Intelligence turned on (macOS 26 or later) the ranking gets smarter."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Also use what is on screen"), isOn: $useScreen)
                    .disabled(!suggestions)
                    .onChange(of: useScreen) { _, value in
                        if value && !Permissions.canReadScreen { Permissions.requestScreenAccess() }
                    }
                Text(L("Reads the text of the window you are pasting into, only while the shelf is open. Needs Screen Recording; nothing is recorded or stored."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("AI tools (MCP)")) {
                Toggle(L("Let AI tools search Clippa"), isOn: $mcpEnabled)
                Toggle(L("Allow them to add and pin items"), isOn: $mcpAllowChanges)
                    .disabled(!mcpEnabled)
                Text(L("Claude, Codex, Cursor and other tools that support MCP can search your clipboard history and pinboards. The connection runs on this Mac; what the tool does with the results depends on the tool."))
                    .font(.caption).foregroundStyle(.secondary)
                if mcpEnabled {
                    snippet(L("Claude Code (Terminal)"), claudeCodeCommand)
                    snippet(L("Claude Desktop, Cursor and others (add to mcpServers)"), desktopConfig)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Button(copied == text ? L("Copied") : L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = text
                }
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    let store: ClippaStore

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Clippa").font(.system(size: 22, weight: .bold))
            Text(L("Version %@", version)).foregroundStyle(.secondary)
            Text(L("Everything you copy, a keystroke away.")).padding(.top, 4)
            Text(L("Free and open source (MIT license). Your data stays on your Macs."))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Link(L("Source code on GitHub"), destination: URL(string: "https://github.com/massimodascola/clippa")!)
                Button(L("Show Data Folder")) { NSWorkspace.shared.open(store.directory) }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }
}
