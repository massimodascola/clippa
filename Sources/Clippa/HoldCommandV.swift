import AppKit

/// "Hold ⌘V to open Clippa" (Settings → Shortcuts).
///
/// A quick ⌘V still pastes as usual; holding it opens the shelf instead.
/// To tell the two apart Clippa has to wait for the key to come up, so it
/// holds back the real key press and, on release, sends its own ⌘V in its
/// place: the app receives it a fraction of a second later, when the key
/// is released. Needs the Accessibility permission, like pasting.
@MainActor
final class HoldCommandV {
    /// Written into every ⌘V Clippa sends itself, so its own key presses
    /// are never taken for the user's.
    nonisolated static let marker: Int64 = 0x434C_5041 // "CLPA"

    /// How long ⌘V must be held to open the shelf.
    var holdDelay: TimeInterval = 0.45
    var onHold: () -> Void = {}
    /// What a quick press does: send ⌘V (replaced in the self-test).
    var sendPaste: () -> Void = { HoldCommandV.sendCommandV() }
    /// True when ⌘V must be left alone (the shelf is open, Paste Stack is on).
    var shouldIgnore: () -> Bool = { false }

    private enum State { case idle, waiting, opened }
    private var state = State.idle
    private var timer: DispatchWorkItem?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// Starts or stops watching ⌘V. Returns false if macOS refused (no
    /// Accessibility permission).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            remove()
            return true
        }
        return install()
    }

    private func install() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<HoldCommandV>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { watcher.handle(type, event) }
        }, userInfo: refcon) else { return false }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func remove() {
        timer?.cancel()
        state = .idle
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        tapSource = nil
    }

    /// Returns nil to swallow the event, or the event to let it through.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == KeyboardLayout.vKeyCode else {
            return pass
        }

        if type == .keyUp {
            switch state {
            case .idle:
                return pass
            case .waiting:
                // Released quickly: an ordinary paste.
                timer?.cancel()
                state = .idle
                sendPaste()
                return nil
            case .opened:
                state = .idle
                return nil
            }
        }

        guard type == .keyDown else { return pass }
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch state {
        case .idle:
            guard flags == .maskCommand, !isRepeat, !shouldIgnore() else { return pass }
            state = .waiting
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .waiting else { return }
                self.state = .opened
                self.onHold()
            }
            timer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
            return nil
        case .waiting:
            // The system key repeat started: it is being held.
            if isRepeat {
                timer?.cancel()
                state = .opened
                onHold()
            }
            return nil
        case .opened:
            return nil
        }
    }

    /// Sends ⌘V to the app in front, marked as Clippa's own.
    nonisolated static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = KeyboardLayout.vKeyCode
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }
}
