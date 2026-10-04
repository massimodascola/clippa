import AppKit
import Carbon.HIToolbox
import ClippaCore
import SwiftUI

/// The borderless bar at the bottom of the screen. It takes the keyboard
/// without activating Clippa, so the app you were using stays in front and
/// receives the paste.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 330),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

/// Opens, drives and closes the shelf.
@MainActor
final class ShelfController: NSObject, NSWindowDelegate {
    let model: ShelfModel
    let panel = ShelfPanel()
    private let pasteService: PasteService
    private let app: AppController
    private var keyMonitor: Any?
    private var target: NSRunningApplication?
    private(set) var isVisible = false
    private lazy var preview = PreviewController(shelf: self)
    private lazy var editor = EditorController(shelf: self)
    private lazy var suggester = SuggestionEngine(store: model.store)

    static let inset: CGFloat = 6
    static let minHeight: CGFloat = 170
    static let compactHeight: CGFloat = 250

    init(app: AppController, store: ClippaStore, pasteService: PasteService) {
        self.app = app
        self.pasteService = pasteService
        model = ShelfModel(store: store)
        super.init()
        model.controller = self
        panel.delegate = self
        let host = NSHostingView(rootView: ShelfView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    // MARK: - Showing and hiding

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // Clippa itself is in front (just opened by hand, or Settings is
            // open): paste into the app whose window is on top.
            target = Self.appBehindClippa() ?? target
        } else {
            target = front
        }
        model.prepareForShow()
        if model.showingSuggestions { refreshSuggestions() }

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let frame = targetFrame(on: screen, height: storedHeight(for: screen))
        model.compact = frame.height < Self.compactHeight
        var start = frame
        start.origin.y -= frame.height * 0.35
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
    }

    func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        removeKeyMonitor()
        preview.close()
        model.showNumbers = false
        if animated {
            var end = panel.frame
            end.origin.y -= end.height * 0.25
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                panel.animator().setFrame(end, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isVisible else { return }
                    self.panel.orderOut(nil)
                }
            })
        } else {
            panel.orderOut(nil)
        }
    }

    /// The app owning the frontmost normal window that is not Clippa's.
    /// Window owners can be read without the Screen Recording permission.
    private static func appBehindClippa() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }

    private func targetFrame(on screen: NSScreen, height: CGFloat) -> NSRect {
        let area = screen.frame
        let maxHeight = area.height * 0.7
        let clamped = min(max(height, Self.minHeight), maxHeight)
        return NSRect(x: area.minX + Self.inset, y: area.minY + Self.inset,
                      width: area.width - Self.inset * 2, height: clamped)
    }

    private func storedHeight(for screen: NSScreen) -> CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: Pref.panelHeight))
    }

    /// Dragging the top edge changes the height; small heights switch to
    /// the compact layout, like Paste.
    func resize(toTop top: CGFloat) {
        guard let screen = panel.screen else { return }
        let height = top - panel.frame.minY
        let frame = targetFrame(on: screen, height: height)
        panel.setFrame(frame, display: true)
        model.compact = frame.height < Self.compactHeight
        UserDefaults.standard.set(Double(frame.height), forKey: Pref.panelHeight)
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Closing when the user clicks elsewhere, but not when one of our
            // own panels (editor, preview) takes the keyboard.
            DispatchQueue.main.async {
                guard self.isVisible, !self.panel.isKeyWindow else { return }
                if let key = NSApp.keyWindow, key === self.editor.panel { return }
                self.hide()
            }
        }
    }

    // MARK: - Actions called by the model and the views

    func paste(_ items: [Item], plainText: Bool) {
        let target = self.target
        hide(animated: false)
        switch pasteService.paste(items, plainText: plainText, into: target) {
        case .needsPermission:
            app.showPastePermissionHelp()
        case .pasted, .copiedOnly:
            break
        }
        storeDidChange()
    }

    @discardableResult
    func copy(_ items: [Item]) -> Bool {
        let done = pasteService.copy(items, plainText: false)
        if done { Sounds.playCopy() }
        storeDidChange()
        return done
    }

    func open(_ item: Item) {
        switch item.kind {
        case .link:
            if let url = Classifier.link(item.text) {
                hide()
                NSWorkspace.shared.open(url)
            }
        case .file:
            let urls = item.text.components(separatedBy: "\n").map { URL(fileURLWithPath: $0) }
            hide()
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        default:
            togglePreview()
        }
    }

    func togglePreview() {
        if model.previewID != nil {
            preview.close()
        } else if let item = model.selectedItems.last {
            preview.show(item)
        }
    }

    func updatePreview() {
        guard model.previewID != nil, let item = model.selectedItems.last else { return }
        preview.show(item)
    }

    func edit(_ item: Item) {
        preview.close()
        editor.edit(item)
    }

    func editorDidClose(saved: Bool) {
        if saved {
            model.reload()
            storeDidChange()
        }
        if isVisible { panel.makeKey() }
    }

    func openSettings() {
        hide()
        app.showSettings()
    }

    func pause() {
        app.pause(for: 3_600)
        model.flash(L("Paused for 1 hour"))
    }

    func storeDidChange() {
        app.storeDidChange()
    }

    func toggleSuggestions() {
        model.showingSuggestions.toggle()
        model.selection = []
        if model.showingSuggestions {
            refreshSuggestions()
        } else {
            model.reload()
        }
    }

    private func refreshSuggestions() {
        model.suggestionsLoading = true
        suggester.suggest(for: target) { [weak self] items, done in
            guard let self, self.model.showingSuggestions else { return }
            self.model.suggestions = items
            self.model.suggestionsLoading = !done
            if self.model.selection.isEmpty || !items.contains(where: { self.model.selection.contains($0.id) }),
               let first = items.first {
                self.model.selection = [first.id]
                self.model.scrollTarget = first.id
            }
        }
    }

    /// Reloads after a change made elsewhere (a new copy, sync, an AI tool).
    func externalChange() {
        guard isVisible else { return }
        model.reload()
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel || event.window === self.preview.panel else {
                return event
            }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    /// Returns true when the event was used.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let quick = Pref.quickPasteFlags
        let plain = Pref.plainTextFlags

        if event.type == .flagsChanged {
            model.showNumbers = flags.contains(quick)
            return false
        }
        let code = Int(event.keyCode)

        // Text fields being edited (rename, pinboard name) keep their keys.
        if model.renamingID != nil || model.editingPinboardID != nil || model.creatingPinboard {
            if code == kVK_Escape {
                model.renamingID = nil
                model.editingPinboardID = nil
                model.creatingPinboard = false
                return true
            }
            return false
        }

        // Quick Paste works everywhere, even while typing a search.
        if flags.contains(quick), let number = Self.digitKeys[code] {
            model.quickPaste(number: number, plainText: quick != plain && flags.contains(plain))
            return true
        }

        if model.searchFocused {
            // The field may not have the keyboard yet (focus moves on the
            // next SwiftUI update): keep fast typing instead of losing it.
            if !(panel.firstResponder is NSTextView), !flags.contains(.command), !flags.contains(.control),
               let characters = event.characters, let scalar = characters.unicodeScalars.first,
               !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 {
                model.searchText += characters
                placeCursorAtEnd()
                return true
            }
            switch code {
            case kVK_Escape:
                if model.isSearching { model.clearSearch() } else { model.searchFocused = false }
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_DownArrow:
                if !model.visibleItems.isEmpty { model.searchFocused = false }
                return true
            default:
                return false
            }
        }

        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        switch code {
        case kVK_Escape:
            if model.previewID != nil { preview.close() }
            else if model.isSearching { model.clearSearch() }
            else if model.showingSuggestions { toggleSuggestions() }
            else { hide() }
        case kVK_LeftArrow, kVK_RightArrow:
            let step = code == kVK_LeftArrow ? -1 : 1
            if command { model.switchList(by: step) } else { model.moveSelection(by: step, extend: shift) }
            updatePreview()
        case kVK_UpArrow where command, kVK_DownArrow where command:
            model.selectEdge(last: code == kVK_DownArrow)
            updatePreview()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.pasteSelection(plainText: flags.contains(plain) && plain != .command)
        case kVK_Space where !command:
            togglePreview()
        case kVK_Delete, kVK_ForwardDelete:
            model.deleteSelection()
        case kVK_Tab:
            model.searchFocused = true
        case kVK_ANSI_A where command: model.selectAll()
        case kVK_ANSI_C where command: model.copySelection()
        case kVK_ANSI_O where command: model.selectedItems.last.map(open)
        case kVK_ANSI_R where command: model.renamingID = model.selection.last
        case kVK_ANSI_E where command: model.selectedItems.last.map(edit)
        case kVK_ANSI_N where command && shift: model.creatingPinboard = true
        case kVK_ANSI_N where command: model.createTextItem()
        case kVK_ANSI_Z where command: model.undo()
        case kVK_ANSI_F where command: model.searchFocused = true
        case kVK_ANSI_G where command: model.showSelectedInList()
        case kVK_ANSI_T where command: pause()
        case kVK_ANSI_Comma where command: openSettings()
        case kVK_ANSI_W where command: hide()
        case kVK_ANSI_Q where command: NSApp.terminate(nil)
        default:
            // Typing anything else starts a search, like Paste.
            if !command, !flags.contains(.control), let characters = event.characters,
               let scalar = characters.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) {
                model.searchFocused = true
                model.searchText += characters
                placeCursorAtEnd()
                return true
            }
            return false
        }
        return true
    }

    /// A focused text field selects all its text; typing must continue
    /// after what was already typed.
    private func placeCursorAtEnd() {
        for delay in [0.0, 0.05] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let editor = self?.panel.firstResponder as? NSTextView else { return }
                let end = (editor.string as NSString).length
                if editor.selectedRange() != NSRange(location: end, length: 0) {
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
        }
    }
}
