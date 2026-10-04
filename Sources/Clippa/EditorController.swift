import AppKit
import ClippaCore

/// Command-E: edit an item's text before pasting it. Formatting is kept
/// when the item has it.
@MainActor
final class EditorController: NSObject, NSWindowDelegate {
    private unowned let shelf: ShelfController
    let panel: NSPanel
    private let textView: NSTextView
    private var item: Item?
    private var saved = false

    init(shelf: ShelfController) {
        self.shelf = shelf
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: true)
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()
        panel.level = .statusBar
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.minSize = NSSize(width: 360, height: 220)

        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: L("Save"), target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        save.bezelColor = .controlAccentColor
        let hint = NSTextField(labelWithString: L("⌘↩ to save"))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let buttons = NSStackView(views: [hint, NSView(), cancel, save])
        buttons.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 12, right: 14)
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        panel.contentView = stack
    }

    func edit(_ item: Item) {
        self.item = item
        saved = false
        panel.title = item.title ?? L("Edit %@", item.kind.name)
        let store = shelf.model.store
        if let rtf = item.representations.first(where: { $0.type == UTI.rtf }),
           let data = store.blobs.read(rtf.blob),
           let text = NSAttributedString(rtf: data, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(text)
            textView.isRichText = true
        } else {
            let plain = item.representations.first { $0.type == UTI.plainText || $0.type == UTI.string }
            let text = plain.flatMap { store.blobs.read($0.blob) }.flatMap { String(data: $0, encoding: .utf8) } ?? item.text
            textView.isRichText = false
            textView.string = text
            textView.font = .systemFont(ofSize: 14)
            textView.textColor = .textColor
        }
        if let screen = shelf.panel.screen {
            let shelfTop = shelf.panel.frame.maxY
            let height = min(420, screen.frame.maxY - shelfTop - 60)
            panel.setFrame(NSRect(x: screen.frame.midX - 290, y: shelfTop + 16, width: 580, height: max(height, 240)), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        textView.selectAll(nil)
    }

    @objc private func save() {
        guard var item else { return }
        let store = shelf.model.store
        let plain = textView.string
        do {
            var reps = [Representation]()
            let plainData = Data(plain.utf8)
            reps.append(Representation(index: 0, type: UTI.plainText, blob: try store.blobs.write(plainData), size: plainData.count))
            if textView.isRichText, let storage = textView.textStorage,
               let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length), documentAttributes: [:]) {
                reps.append(Representation(index: 0, type: UTI.rtf, blob: try store.blobs.write(rtf), size: rtf.count))
            }
            let kind = Classifier.kind(forText: plain)
            item.kind = kind
            item.text = kind == .color ? (Classifier.hexColor(plain) ?? plain) : plain
            item.representations = reps
            item.byteSize = reps.reduce(0) { $0 + $1.size }
            item.contentHash = BlobStore.hash(Data((kind.rawValue + "\n" + plain).utf8))
            item.linkTitle = nil
            item.linkImage = nil
            try store.update(item)
            saved = true
        } catch {
            NSSound.beep()
            return
        }
        panel.close()
    }

    @objc private func cancel() {
        panel.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // A new empty item (Command-N) that was never written disappears.
            if !saved, let item, item.text.isEmpty {
                _ = try? shelf.model.store.delete(ids: [item.id])
                shelf.model.reload()
            }
            shelf.editorDidClose(saved: saved || (item?.text.isEmpty ?? false))
            item = nil
        }
    }
}
