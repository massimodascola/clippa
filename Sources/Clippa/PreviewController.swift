import AppKit
import ClippaCore
import Quartz
import SwiftUI

/// The large preview shown above the shelf with the Space bar.
@MainActor
final class PreviewController {
    private unowned let shelf: ShelfController
    let panel: NSPanel

    init(shelf: ShelfController) {
        self.shelf = shelf
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
    }

    func show(_ item: Item) {
        shelf.model.previewID = item.id
        let shelfFrame = shelf.panel.frame
        guard let screen = shelf.panel.screen else { return }
        let width = min(720, screen.frame.width * 0.55)
        let height = min(480, screen.frame.maxY - shelfFrame.maxY - 60)
        guard height > 160 else { return }
        let frame = NSRect(x: screen.frame.midX - width / 2, y: shelfFrame.maxY + 14, width: width, height: height)
        panel.contentView = NSHostingView(rootView: PreviewView(item: item, store: shelf.model.store, close: { [weak self] in
            self?.close()
        }))
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func close() {
        shelf.model.previewID = nil
        panel.orderOut(nil)
    }
}

struct PreviewView: View {
    let item: Item
    let store: ClippaStore
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.icon(for: item.sourceBundleID)).resizable().frame(width: 20, height: 20)
                Text(item.title ?? item.sourceAppName ?? item.kind.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(L("Copied %@ on %@", item.copiedAt.formatted(date: .abbreviated, time: .shortened), item.deviceName))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(fullText)
                    .font(.system(size: 13, design: isCode ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .link:
            VStack(alignment: .leading, spacing: 10) {
                if let image = PreviewCache.image(item.linkImage, store: store) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(item.linkTitle ?? "").font(.system(size: 16, weight: .semibold))
                Text(item.text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
            }
            .padding(16)
        case .image:
            VStack(spacing: 8) {
                if let image = fullImage {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
                if let ocr = item.ocrText, !ocr.isEmpty {
                    ScrollView {
                        Text(ocr).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 70)
                }
            }
            .padding(14)
        case .color:
            let rgb = Classifier.rgb(item.text) ?? (0, 0, 0)
            let color = NSColor(deviceRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: color)).frame(maxHeight: .infinity)
                HStack(spacing: 24) {
                    value("HEX", item.text)
                    value("RGB", "\(Int(rgb.red * 255)), \(Int(rgb.green * 255)), \(Int(rgb.blue * 255))")
                    value("HSB", "\(Int(color.hueComponent * 360))°, \(Int(color.saturationComponent * 100))%, \(Int(color.brightnessComponent * 100))%")
                }
            }
            .padding(16)
        case .file:
            let paths = item.text.components(separatedBy: "\n")
            VStack(spacing: 6) {
                if FileManager.default.fileExists(atPath: paths[0]) {
                    QuickLookView(url: URL(fileURLWithPath: paths[0]))
                } else {
                    Text(L("This file is not available on this Mac.")).foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                }
                Text(paths.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(4).textSelection(.enabled)
            }
            .padding(12)
        }
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
        }
    }

    private var fullText: String {
        let plain = item.representations.first { $0.type == UTI.plainText || $0.type == UTI.string }
        if let plain, let data = store.blobs.read(plain.blob), let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(200_000))
        }
        return item.text
    }

    private var isCode: Bool { TextHeuristics.looksLikeCode(item.text) }

    private var fullImage: NSImage? {
        guard let rep = item.representations.first(where: { UTI.imageTypes.contains($0.type) }) else {
            return PreviewCache.image(item.thumbnail, store: store)
        }
        return NSImage(contentsOf: store.blobs.url(for: rep.blob))
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
}
