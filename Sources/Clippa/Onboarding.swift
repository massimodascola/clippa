import AppKit
import ClippaCore
import Combine
import SwiftUI

/// First launch: how to open Clippa, the two permissions, how long to keep
/// the history.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppController

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(app: app) { [weak self] in self?.finish() })
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Pref.onboardingDone)
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(true, forKey: Pref.onboardingDone)
            app.onboardingFinished()
        }
    }
}

struct OnboardingView: View {
    let app: AppController
    let done: () -> Void
    @State private var step = 0
    @State private var canPaste = Permissions.canPaste
    @State private var clipboardAccess = Permissions.clipboardAccess
    @State private var openAtLogin = true
    @AppStorage(Pref.keepHistory) private var keepHistory = HistoryRetention.default.rawValue
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var shortcut: String {
        Shortcut.load(Pref.activateShortcut, default: .activateDefault)?.displayString ?? "⇧⌘V"
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                default: history
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 36)
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Circle().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 {
                    Button(L("Back")) { step -= 1 }
                }
                Button(step == 2 ? L("Start Using Clippa") : L("Continue")) {
                    if step == 2 {
                        if openAtLogin { _ = app.setOpenAtLogin(true) }
                        done()
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .onReceive(refresh) { _ in
            canPaste = Permissions.canPaste
            clipboardAccess = Permissions.clipboardAccess
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
            Text(L("Welcome to Clippa")).font(.system(size: 26, weight: .bold))
            Text(L("Clippa keeps everything you copy: text, links, images, files and colors. Find it again in seconds, and pin what you reuse."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text(shortcut)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                Text(L("opens Clippa from any app. You can change it in Settings."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Two permissions")).font(.system(size: 22, weight: .bold))
            Text(L("Clippa works on this Mac only. These permissions let it do its job; you can change them at any time."))
                .foregroundStyle(.secondary)
            if #available(macOS 15.4, *) {
                PermissionCard(granted: clipboardAccess == .allowed,
                               title: L("Read the clipboard"),
                               detail: L("macOS will ask whether Clippa may paste from other apps the first time you copy something: choose “Always Allow”. You can also set it in Privacy & Security → Paste from Other Apps."),
                               button: L("Open Settings…"), action: Permissions.openClipboardAccessSettings)
            }
            PermissionCard(granted: canPaste,
                           title: L("Paste into your apps"),
                           detail: L("Accessibility (Device Control and Data Access on macOS 27) lets Clippa press ⌘V for you in the app you are using. Without it, Clippa copies the item and you press ⌘V yourself."),
                           button: L("Allow…"), action: Permissions.requestAccessibility)
            Spacer()
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("How long should Clippa keep things?")).font(.system(size: 22, weight: .bold))
            Text(L("Older items are deleted automatically. Pinned items never are, and any item can have its own rule (right-click → Keep)."))
                .foregroundStyle(.secondary)
            Picker("", selection: $keepHistory) {
                ForEach(HistoryRetention.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Toggle(L("Open Clippa at login"), isOn: $openAtLogin)
                .padding(.top, 8)
            Spacer()
        }
    }
}

struct PermissionCard: View {
    let granted: Bool
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { Button(button, action: action) }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
