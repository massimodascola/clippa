import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, e.g. Shift-Command-V.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt  // NSEvent.ModifierFlags raw value (device-independent part)

    static let activateDefault = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue)
    static let stackDefault = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    /// "⇧⌘V", using the key's label in the current keyboard layout.
    var displayString: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + KeyboardLayout.label(for: UInt16(keyCode))
    }

    static func load(_ key: String, default value: Shortcut) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return value }
        if data.isEmpty { return nil } // the user cleared it
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? value
    }

    static func save(_ shortcut: Shortcut?, key: String) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Reads the current keyboard layout, so shortcuts show the right letter
/// and Clippa finds the V key on non-QWERTY layouts.
enum KeyboardLayout {
    static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    static func label(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return L("Space")
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            if let number = functionKeys[Int(keyCode)] { return "F\(number)" }
            return character(for: keyCode)?.uppercased() ?? "?"
        }
    }

    /// Function key codes are not in order, so they are listed one by one.
    private static let functionKeys: [Int: Int] = {
        [kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8,
         kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14,
         kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20]
    }()

    /// The key code that types `character` in the current layout.
    static func keyCode(for character: String) -> CGKeyCode? {
        for code in 0..<128 where self.character(for: UInt16(code))?.lowercased() == character {
            return CGKeyCode(code)
        }
        return nil
    }

    /// The V of Command-V, wherever it is on this keyboard.
    static var vKeyCode: CGKeyCode {
        keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
    }
}

/// Global hotkeys through the Carbon API: no permission needed.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    /// Registers (or replaces) the hotkey with this id. Returns false if
    /// another app already uses the combination.
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard let shortcut else { return true }
        installIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_5041), id: id) // "CLPA"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
