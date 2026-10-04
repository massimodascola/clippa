import AppKit
import ClippaCore
import ServiceManagement

/// Owns everything: the store, the clipboard monitor, the shelf, Paste
/// Stack, sync, the menu bar icon and the windows.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) weak var shared: AppController?

    private(set) var store: ClippaStore!
    private var monitor: ClipboardMonitor!
    private var enricher: Enricher!
    private(set) var shelf: ShelfController!
    private(set) var stack: PasteStack!
    private(set) var sync: SyncCoordinator!
    private var statusItem: NSStatusItem?
    private var housekeeping: Timer?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?

    private enum HotKey: UInt32 {
        case activate = 1
        case stack = 2
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared = self
        Pref.registerDefaults()
        do {
            store = try ClippaStore(deviceID: Pref.thisDeviceID, deviceName: Pref.thisDeviceName)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Clippa can't open its data")
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let pasteService = PasteService(store: store)
        shelf = ShelfController(app: self, store: store, pasteService: pasteService)
        stack = PasteStack(store: store)
        stack.isShelfKey = { [weak self] in self?.shelf.panel.isKeyWindow ?? false }
        enricher = Enricher(store: store) { [weak self] _ in self?.shelf.externalChange() }
        sync = SyncCoordinator(store: store)
        sync.onImport = { [weak self] in self?.shelf.externalChange() }

        monitor = ClipboardMonitor { [weak self] content in self?.save(content) }
        monitor.start()

        registerHotKeys()
        updateStatusItem()
        sync.configure()
        runHousekeeping()
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runHousekeeping() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeeping = timer

        // clippa-mcp tells us when an AI tool changed something.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppController.shared?.shelf.externalChange()
                    AppController.shared?.sync.scheduleSoon()
                }
            }
        }, ClippaSignal.storeChanged as CFString, nil, .deliverImmediately)

        if !UserDefaults.standard.bool(forKey: Pref.onboardingDone) {
            showOnboarding()
        }
        DebugHooks.installIfRequested(app: self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening Clippa again (from Finder or Spotlight) shows the shelf.
        shelf.show()
        return false
    }

    // MARK: - Capture

    private func save(_ content: CapturedContent) {
        guard let item = try? store.save(content) else { return }
        enricher.process(item)
        stack.add(item)
        shelf.externalChange()
        sync.scheduleSoon()
    }

    func storeDidChange() {
        sync.scheduleSoon()
    }

    /// Applies Keep History and the per-item rules, then frees unused files.
    func runHousekeeping() {
        let removed = (try? store.purgeExpired(retention: Pref.keepHistoryValue)) ?? 0
        let lastCollection = UserDefaults.standard.double(forKey: "lastGarbageCollection")
        if removed > 0 || Date().timeIntervalSince1970 - lastCollection > 86_400 {
            _ = try? store.collectGarbage()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastGarbageCollection")
        }
        if removed > 0 { shelf.externalChange() }
    }

    // MARK: - Hotkeys

    func registerHotKeys() {
        HotKeyCenter.shared.register(id: HotKey.activate.rawValue,
                                     shortcut: Shortcut.load(Pref.activateShortcut, default: .activateDefault)) { [weak self] in
            self?.shelf.toggle()
        }
        HotKeyCenter.shared.register(id: HotKey.stack.rawValue,
                                     shortcut: Shortcut.load(Pref.stackShortcut, default: .stackDefault)) { [weak self] in
            self?.stack.toggle()
        }
    }

    // MARK: - Pause

    func pause(for seconds: TimeInterval?) {
        Pref.pausedUntilDate = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
        updateStatusItem()
    }

    func resume() {
        Pref.pausedUntilDate = nil
        updateStatusItem()
    }

    var isPaused: Bool { monitor?.isPaused ?? false }

    // MARK: - Menu bar

    func updateStatusItem() {
        guard UserDefaults.standard.bool(forKey: Pref.showMenuBarIcon) else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "clippa_status"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        let symbol = isPaused ? "pause.circle" : "doc.on.clipboard"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Clippa")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.appearsDisabled = isPaused
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { buildMenu(menu) }
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = menu.addItem(withTitle: L("Open Clippa"), action: #selector(openShelf), keyEquivalent: "")
        if let shortcut = Shortcut.load(Pref.activateShortcut, default: .activateDefault) {
            open.title = L("Open Clippa") + "  " + shortcut.displayString
        }
        let stackTitle = stack.isActive ? L("Close Paste Stack") : L("Paste Stack")
        let stackItem = menu.addItem(withTitle: stackTitle, action: #selector(toggleStack), keyEquivalent: "")
        if let shortcut = Shortcut.load(Pref.stackShortcut, default: .stackDefault) {
            stackItem.title = stackTitle + "  " + shortcut.displayString
        }
        menu.addItem(.separator())
        if isPaused, let until = Pref.pausedUntilDate {
            let info = until == .distantFuture ? L("Paused") : L("Paused until %@", until.formatted(date: .omitted, time: .shortened))
            menu.addItem(withTitle: info, action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: L("Resume Clippa"), action: #selector(resumeFromMenu), keyEquivalent: "")
        } else {
            let pauseItem = menu.addItem(withTitle: L("Pause Clippa"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, seconds) in [(L("For 15 Minutes"), 900.0), (L("For 1 Hour"), 3_600), (L("For 8 Hours"), 28_800),
                                     (L("Until I Resume"), -1)] {
                let entry = submenu.addItem(withTitle: title, action: #selector(pauseFromMenu(_:)), keyEquivalent: "")
                entry.representedObject = seconds
                entry.target = self
            }
            pauseItem.submenu = submenu
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L("About Clippa"), action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit Clippa"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
    }

    @objc private func openShelf() {
        // Let the menu close first so the right app is in front.
        DispatchQueue.main.async { self.shelf.show() }
    }

    @objc private func toggleStack() { stack.toggle() }
    @objc private func resumeFromMenu() { resume() }
    @objc private func openSettings() { showSettings() }
    @objc private func openAbout() { showSettings(tab: .about) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pauseFromMenu(_ sender: NSMenuItem) {
        let seconds = sender.representedObject as? Double ?? -1
        pause(for: seconds < 0 ? nil : seconds)
    }

    // MARK: - Windows

    func showSettings(tab: SettingsTab = .general) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show(tab: tab)
    }

    func showOnboarding() {
        if onboardingWindow == nil { onboardingWindow = OnboardingWindowController(app: self) }
        onboardingWindow?.show()
    }

    func onboardingFinished() {
        onboardingWindow = nil
    }

    /// The first paste without Accessibility: explain, like Paste does.
    func showPastePermissionHelp() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Allow Clippa to paste for you")
        alert.informativeText = L("The item is on the clipboard: press ⌘V to paste it.\n\nTo paste straight into the app you are using, allow Clippa in System Settings → Privacy & Security → Accessibility (Device Control and Data Access on macOS 27). Clippa only sends ⌘V to the app in front.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Not Now"))
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestAccessibility()
        }
    }

    // MARK: - Settings side effects

    func setOpenAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }
}

extension ShelfController {
    func startPasteStack() {
        hide()
        AppController.shared?.stack.start()
    }

    func confirmDeletePinboard(_ pinboard: Pinboard) {
        let count = (try? model.store.pinboardItemCounts()[pinboard.id]) ?? 0
        let alert = NSAlert()
        alert.messageText = L("Delete “%@”?", pinboard.name)
        alert.informativeText = count == 0 ? L("The pinboard is empty.")
            : L("Its %lld items will be deleted too. This can't be undone.", count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.model.deletePinboard(pinboard.id) }
                self?.panel.makeKey()
            }
        }
    }

    func rotate(_ item: Item, clockwise: Bool) {
        let store = model.store
        guard let rep = item.representations.first(where: { UTI.imageTypes.contains($0.type) }),
              let data = store.blobs.read(rep.blob), let rotated = ImageTools.rotate(data, clockwise: clockwise),
              let blob = try? store.blobs.write(rotated) else { return }
        var changed = item
        changed.representations = [Representation(index: 0, type: UTI.png, blob: blob, size: rotated.count)]
        changed.thumbnail = ImageTools.thumbnail(of: rotated).flatMap { try? store.blobs.write($0) }
        changed.imageWidth = item.imageHeight
        changed.imageHeight = item.imageWidth
        changed.byteSize = rotated.count
        changed.contentHash = BlobStore.hash(Data((ItemKind.image.rawValue + "\n" + BlobStore.hash(rotated)).utf8))
        try? store.update(changed)
        model.reload()
        storeDidChange()
    }
}
