import AppKit
import ClippaCore
import ClippaPasteboard

/// Puts items back on the clipboard and, when allowed, pastes them into the
/// app you were using by sending it Command-V. That keystroke is the only
/// thing Clippa sends to other apps.
@MainActor
final class PasteService {
    private let store: ClippaStore

    init(store: ClippaStore) {
        self.store = store
    }

    enum Result {
        case pasted
        case copiedOnly
        case needsPermission
    }

    /// Copies the items and pastes them into `target`.
    @discardableResult
    func paste(_ items: [Item], plainText: Bool, into target: NSRunningApplication?) -> Result {
        guard copy(items, plainText: plainText) else { return .copiedOnly }
        for item in items {
            try? store.recordPaste(itemID: item.id, into: target?.bundleIdentifier)
        }
        guard Pref.destination == .activeApp, Permissions.canPaste else {
            Sounds.playCopy()
            return Pref.destination == .activeApp ? .needsPermission : .copiedOnly
        }
        Sounds.playPaste()
        // Give the shelf time to close and the target app time to take the
        // keyboard back before the keystroke arrives.
        var delay = 0.08
        if let target, !target.isActive {
            // Clippa was in front: bring the app back first, then paste.
            target.activate()
            delay = 0.25
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.sendCommandV()
        }
        return .pasted
    }

    /// Copies the items to the clipboard only. A single item also moves to
    /// the front of the history, since it is the latest thing copied.
    @discardableResult
    func copy(_ items: [Item], plainText: Bool) -> Bool {
        let plain = plainText || UserDefaults.standard.bool(forKey: Pref.alwaysPlainText)
        let written = PasteboardWriter.write(items, store: store, mode: plain ? .plainText : .original)
        if written, items.count == 1 {
            try? store.markCopied(items[0].id)
        }
        return written
    }

    static func sendCommandV() {
        HoldCommandV.sendCommandV()
    }
}
