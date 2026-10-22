import AppKit

/// "Hold ⌘V to open Clippa" (Settings → Shortcuts).
///
/// A quick ⌘V still pastes as usual; holding it opens the shelf instead.
/// To tell the two apart Clippa has to wait for the key to come up, so it
/// holds back the real key press and, on release, sends its own ⌘V in its
/// place: the app receives it a fraction of a second later, when the key
/// is released. Needs the Accessibility permission, like pasting.
///
/// While it is on, every key press of the Mac passes through this watch,
/// so it runs on a thread of its own: it never waits for Clippa's main
/// thread, which may be busy (saving a big copy, say) for a moment.
final class HoldCommandV: @unchecked Sendable {
    /// Written into every ⌘V Clippa sends itself, so its own key presses
    /// are never taken for the user's.
    static let marker: Int64 = 0x434C_5041 // "CLPA"

    /// How long ⌘V must be held to open the shelf.
    var holdDelay: TimeInterval = 0.45
    /// Opens the shelf. Called on the main thread.
    var onHold: @MainActor () -> Void = {}
    /// What a quick press does: send ⌘V (replaced in the self-test).
    var sendPaste: () -> Void = {}

    /// True while ⌘V must be left alone (the shelf is open, Paste Stack is
    /// on). Set on the main thread, read by the keyboard thread.
    var isSuspended: Bool {
        get { lock.withLock { suspended } }
        set { lock.withLock { suspended = newValue } }
    }

    var isRunning: Bool { lock.withLock { tap != nil } }

    private enum State { case idle, waiting, opened }
    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var suspended = false
    private var state = State.idle
    private var pending: DispatchWorkItem?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// The V key on this keyboard. The layout can only be read on the main
    /// thread, so it is copied here and refreshed when the layout changes.
    private var vKey = CGKeyCode(9)

    private let timers = DispatchQueue(label: "clippa.hold-command-v", qos: .userInteractive)

    @MainActor
    init() {
        vKey = KeyboardLayout.vKeyCode
        sendPaste = { [unowned self] in Self.sendCommandV(key: self.lock.withLock { self.vKey }) }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main) { [weak self] _ in
            // KeyboardLayout forgets its copy in its own observer: read it after.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let key = KeyboardLayout.vKeyCode
                    self?.lock.withLock { self?.vKey = key }
                }
            }
        }
    }

    /// Starts or stops watching ⌘V. Returns false if macOS refused (no
    /// Accessibility permission).
    @MainActor
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            remove()
            return true
        }
        return install()
    }

    @MainActor
    private func install() -> Bool {
        guard !isRunning else { return true }
        let key = KeyboardLayout.vKeyCode
        lock.withLock { vKey = key }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HoldCommandV>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }, userInfo: refcon) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            lock.withLock { runLoop = loop }
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "Clippa keyboard watch"
        thread.qualityOfService = .userInteractive
        lock.withLock { tap = port }
        thread.start()
        started.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    @MainActor
    private func remove() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            pending?.cancel()
            pending = nil
            state = .idle
            defer {
                tap = nil
                runLoop = nil
            }
            return (tap, runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// Returns nil to swallow the event, or the event to let it through.
    /// Runs on the keyboard thread (on the main thread in the self-test).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == lock.withLock({ vKey }) else {
            return pass
        }

        enum Action { case none, paste, open }
        var action = Action.none
        let result: Unmanaged<CGEvent>? = lock.withLock {
            if type == .keyUp {
                switch state {
                case .idle:
                    return pass
                case .waiting:
                    // Released quickly: an ordinary paste.
                    pending?.cancel()
                    pending = nil
                    state = .idle
                    action = .paste
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
                guard flags == .maskCommand, !isRepeat, !suspended else { return pass }
                state = .waiting
                let work = DispatchWorkItem { [weak self] in self?.holdElapsed() }
                pending = work
                timers.asyncAfter(deadline: .now() + holdDelay, execute: work)
                return nil
            case .waiting:
                // The system key repeat started: it is being held.
                if isRepeat {
                    pending?.cancel()
                    pending = nil
                    state = .opened
                    action = .open
                }
                return nil
            case .opened:
                return nil
            }
        }
        switch action {
        case .paste: sendPaste()
        case .open: openShelf()
        case .none: break
        }
        return result
    }

    private func holdElapsed() {
        let opens = lock.withLock { () -> Bool in
            guard state == .waiting else { return false }
            state = .opened
            pending = nil
            return true
        }
        if opens { openShelf() }
    }

    private func openShelf() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onHold() }
        }
    }

    /// Sends ⌘V to the app in front, marked as Clippa's own.
    @MainActor
    static func sendCommandV() {
        sendCommandV(key: KeyboardLayout.vKeyCode)
    }

    static func sendCommandV(key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }
}
