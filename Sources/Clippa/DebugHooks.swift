import AppKit
import Carbon.HIToolbox
import ClippaCore

/// Test automation for development, off unless Clippa is started with the
/// CLIPPA_DEBUG_HOOKS environment variable. Then
///
///     notifyutil -p com.massimodascola.clippa.debug
///
/// makes Clippa run the commands in <data folder>/debug-commands.txt, one
/// per line, and write "done" to debug-status.txt. Commands: show, hide,
/// key <code> [command,shift,option,control], type <text>,
/// flags [modifiers], click <index> [modifiers], wait <seconds>,
/// suggestions, suggestion, newpinboard <name>, pin <pinboard>, list <history|pinboard>,
/// keep <automatic|hour|day|week|month|year|forever>,
/// settings <tab number>, stack, onboarding, close-windows.
@MainActor
enum DebugHooks {
    static func installIfRequested(app: AppController) {
        guard ProcessInfo.processInfo.environment["CLIPPA_DEBUG_HOOKS"] != nil else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let app = AppController.shared else { return }
                    Task { await DebugHooks.run(app: app) }
                }
            }
        }, "com.massimodascola.clippa.debug" as CFString, nil, .deliverImmediately)
    }

    private static func run(app: AppController) async {
        let directory = app.store.directory
        let status = directory.appendingPathComponent("debug-status.txt")
        try? "running".write(to: status, atomically: true, encoding: .utf8)
        let script = (try? String(contentsOf: directory.appendingPathComponent("debug-commands.txt"), encoding: .utf8)) ?? ""
        for line in script.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = parts.first else { continue }
            let argument = parts.count > 1 ? parts[1] : ""
            switch command {
            case "show": app.shelf.show()
            case "hide": app.shelf.hide()
            case "key":
                let pieces = argument.split(separator: " ").map(String.init)
                if let code = UInt16(pieces.first ?? "") {
                    press(code, flags: modifiers(pieces.dropFirst().joined(separator: ",")), app: app)
                }
            case "type":
                for character in argument {
                    send(keyEvent(.keyDown, code: 0, flags: [], characters: String(character), app: app), app: app)
                }
            case "flags":
                send(keyEvent(.flagsChanged, code: UInt16(kVK_Command), flags: modifiers(argument), characters: "", app: app), app: app)
            case "click":
                let pieces = argument.split(separator: " ").map(String.init)
                if let index = Int(pieces.first ?? ""), app.shelf.model.visibleItems.indices.contains(index) {
                    app.shelf.model.click(app.shelf.model.visibleItems[index], modifiers: modifiers(pieces.dropFirst().joined(separator: ",")))
                }
            case "suggestions":
                app.shelf.toggleSuggestions()
            case "suggestion":
                if let token = app.shelf.model.filterSuggestions.first { app.shelf.model.apply(token) }
            case "newpinboard":
                app.shelf.model.createPinboard(name: argument, color: .blue)
            case "pin":
                let model = app.shelf.model
                if let pinboard = model.pinboards.first(where: { $0.name == argument }) {
                    model.pin(model.selectedItemsInOrder.map(\.id), to: pinboard.id)
                }
            case "list":
                let model = app.shelf.model
                if argument == "history" { model.show(list: .history) }
                else if let pinboard = model.pinboards.first(where: { $0.name == argument }) { model.show(list: .pinboard(pinboard.id)) }
            case "keep":
                if let choice = KeepChoice(rawValue: argument) {
                    app.shelf.model.setKeep(choice, for: app.shelf.model.selection)
                }
            case "wait":
                try? await Task.sleep(for: .seconds(Double(argument) ?? 0.5))
            case "settings":
                app.showSettings(tab: SettingsTab(rawValue: Int(argument) ?? 0) ?? .general)
            case "stack":
                app.stack.toggle()
            case "onboarding":
                app.showOnboarding()
            case "close-windows":
                for window in NSApp.windows where window.isVisible && !(window is NSPanel) { window.close() }
            default:
                break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? "done".write(to: status, atomically: true, encoding: .utf8)
    }

    private static func modifiers(_ text: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in text.split(separator: ",") {
            switch name {
            case "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            case "control": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    private static func press(_ code: UInt16, flags: NSEvent.ModifierFlags, app: AppController) {
        let characters: String
        switch Int(code) {
        case kVK_Return: characters = "\r"
        case kVK_Escape: characters = "\u{1b}"
        case kVK_Space: characters = " "
        case kVK_Tab: characters = "\t"
        case kVK_Delete: characters = "\u{7f}"
        case kVK_LeftArrow: characters = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: characters = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case kVK_UpArrow: characters = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: characters = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default: characters = KeyboardLayout.character(for: code) ?? ""
        }
        send(keyEvent(.keyDown, code: code, flags: flags, characters: characters, app: app), app: app)
    }

    private static func keyEvent(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags,
                                 characters: String, app: AppController) -> NSEvent {
        let window = NSApp.keyWindow ?? app.shelf.panel
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                isARepeat: false, keyCode: code)!
    }

    /// Same path as a real key press: the event goes through the app's
    /// event queue, so Clippa's key handling and the focused control see it
    /// exactly as they would see the keyboard.
    private static func send(_ event: NSEvent, app: AppController) {
        NSApp.postEvent(event, atStart: false)
    }
}
