import AppKit
import ClippaCore

/// Puts saved items back on the macOS pasteboard.
public enum PasteboardWriter {
    /// Added to everything Clippa writes, so its own clipboard monitor does
    /// not save the same thing again.
    public static let ownType = NSPasteboard.PasteboardType("com.massimodascola.clippa.own")

    public enum Mode: Sendable {
        /// Every format that was copied (styles, images, files).
        case original
        /// Text only, without formatting.
        case plainText
    }

    @discardableResult
    public static func write(_ items: [Item], store: ClippaStore, mode: Mode,
                             to pasteboard: NSPasteboard = .general) -> Bool {
        guard !items.isEmpty else { return false }
        var pasteboardItems: [NSPasteboardItem]

        if items.count == 1, mode == .original || items[0].kind == .image || items[0].kind == .file {
            pasteboardItems = restore(items[0], store: store)
        } else if items.allSatisfy({ $0.kind == .file }) {
            // Several file items paste as one selection of files.
            pasteboardItems = items.flatMap { restore($0, store: store) }
        } else {
            let text = items.map { plainText(of: $0, store: store) }.joined(separator: "\n")
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            pasteboardItems = [item]
        }
        if pasteboardItems.isEmpty {
            // Blobs missing (e.g. still syncing): fall back to the saved text.
            let item = NSPasteboardItem()
            item.setString(items.map(\.text).joined(separator: "\n"), forType: .string)
            pasteboardItems = [item]
        }
        pasteboardItems[0].setData(Data(), forType: ownType)
        pasteboardItems[0].setString(ClippaPaths.bundleID, forType: NSPasteboard.PasteboardType(UTI.source))

        pasteboard.clearContents()
        return pasteboard.writeObjects(pasteboardItems)
    }

    /// The item's text without formatting: what "Paste as Plain Text" uses.
    public static func plainText(of item: Item, store: ClippaStore) -> String {
        for type in [UTI.plainText, UTI.string] {
            if let rep = item.representations.first(where: { $0.type == type }),
               let data = store.blobs.read(rep.blob), let string = String(data: data, encoding: .utf8) {
                return string
            }
        }
        if item.kind == .text, let rtf = item.representations.first(where: { $0.type == UTI.rtf }),
           let data = store.blobs.read(rtf.blob),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            return attributed.string
        }
        return item.text
    }

    /// Rebuilds the pasteboard items exactly as they were copied.
    private static func restore(_ item: Item, store: ClippaStore) -> [NSPasteboardItem] {
        let groups = Dictionary(grouping: item.representations, by: \.index)
        return groups.keys.sorted().compactMap { index in
            let pasteboardItem = NSPasteboardItem()
            var wrote = false
            for rep in groups[index] ?? [] {
                guard let data = store.blobs.read(rep.blob) else { continue }
                pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(rep.type))
                wrote = true
            }
            return wrote ? pasteboardItem : nil
        }
    }
}
