import AppKit
import ClippaCore
import ClippaPasteboard
import Observation
import SwiftUI

/// Paste Stack (Shift-Command-C): copy several things, then paste them one
/// after the other with Command-V, in order. Each pasted item leaves the
/// stack. While it is on, Clippa watches Command-V and puts the next item
/// on the clipboard just before the app reads it (needs Accessibility).
@MainActor
@Observable
final class PasteStack {
    private(set) var items: [Item] = []
    private(set) var isActive = false
    var reversed: Bool {
        didSet { UserDefaults.standard.set(reversed, forKey: Pref.stackDirectionReversed) }
    }

    @ObservationIgnored private let store: ClippaStore
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored var isShelfKey: () -> Bool = { false }

    init(store: ClippaStore) {
        self.store = store
        reversed = UserDefaults.standard.bool(forKey: Pref.stackDirectionReversed)
    }

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        items = []
        if !Permissions.canPaste { Permissions.requestAccessibility() }
        installTap()
        showPanel()
    }

    func stop() {
        isActive = false
        items = []
        removeTap()
        panel?.orderOut(nil)
    }

    /// Called for every new copy while the stack is on.
    func add(_ item: Item) {
        guard isActive else { return }
        items.removeAll { $0.id == item.id }
        items.append(item)
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
    }

    /// The item the next Command-V will paste.
    var next: Item? {
        reversed ? items.last : items.first
    }

    var hasAccess: Bool { Permissions.canPaste }

    // MARK: - Command-V

    /// Runs inside the event tap, before the app sees the keystroke.
    fileprivate func handleCommandV() {
        guard let item = next else { return }
        PasteboardWriter.write([item], store: store, mode: UserDefaults.standard.bool(forKey: Pref.alwaysPlainText) ? .plainText : .original)
        Log.attempt("Paste Stack: recordPaste failed") { try store.recordPaste(itemID: item.id, into: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
        items.removeAll { $0.id == item.id }
        Sounds.playPaste()
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let stack = Unmanaged<PasteStack>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { stack.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown, flags == .maskCommand, key == KeyboardLayout.vKeyCode,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               event.getIntegerValueField(.eventSourceUserData) != HoldCommandV.marker {
                MainActor.assumeIsolated {
                    if !stack.isShelfKey() { stack.handleCommandV() }
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else {
            Log.warning("Paste Stack: macOS refused to watch ⌘V (Accessibility not allowed)")
            return
        }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func removeTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        tapSource = nil
    }

    // MARK: - Panel

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let size = NSSize(width: 260, height: min(460, screen.visibleFrame.height - 80))
            panel.setFrame(NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                                  y: screen.visibleFrame.maxY - size.height - 16,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 420),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PasteStackView(stack: self, store: store))
        return panel
    }
}

struct PasteStackView: View {
    @Bindable var stack: PasteStack
    let store: ClippaStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.accentColor)
                Text(L("Paste Stack")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { stack.reversed.toggle() } label: {
                    Image(systemName: stack.reversed ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.plain)
                .help(L("Change the order"))
                Button { stack.stop() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help(L("Close Paste Stack (⇧⌘C)"))
            }
            .padding(12)
            Divider()
            if !stack.hasAccess {
                Text(L("Allow Clippa in Privacy & Security → Accessibility to paste the stack in order."))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(10)
            }
            if stack.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                    Text(L("Copy items to add them.")).font(.system(size: 12, weight: .medium))
                    Text(L("Then press ⌘V to paste them one by one.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .multilineTextAlignment(.center)
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        let ordered = stack.reversed ? Array(stack.items.reversed()) : stack.items
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 8) {
                                Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(index == 0 ? Color.white : Color.secondary)
                                    .frame(width: 20, height: 20)
                                    .background(index == 0 ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
                                if item.kind == .image, let image = PreviewCache.image(item.thumbnail, store: store) {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 34)
                                } else {
                                    Text(item.text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 12)).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Button { stack.remove(item) } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(Color.primary.opacity(index == 0 ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}
