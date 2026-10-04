import AppKit
import ClippaCore
import ClippaPasteboard
import SwiftUI
import UniformTypeIdentifiers

enum TextHeuristics {
    /// Code and terminal commands read better in a monospaced font.
    static func looksLikeCode(_ text: String) -> Bool {
        let sample = text.prefix(600)
        let symbols = sample.filter { "{}[]();=<>$#/\\|\"".contains($0) }.count
        return symbols > max(5, sample.count / 18) || sample.contains("    ") || sample.contains("\t")
    }
}

/// Images and formatted text for the cards, decoded once.
@MainActor
enum PreviewCache {
    private static let images = NSCache<NSString, NSImage>()
    private static let texts = NSCache<NSString, NSAttributedString>()

    static func image(_ hash: String?, store: ClippaStore) -> NSImage? {
        guard let hash else { return nil }
        if let cached = images.object(forKey: hash as NSString) { return cached }
        guard let image = NSImage(contentsOf: store.blobs.url(for: hash)) else { return nil }
        images.setObject(image, forKey: hash as NSString)
        return image
    }

    /// Formatted text of an RTF item, with sizes tamed for a small card.
    static func richText(of item: Item, store: ClippaStore) -> NSAttributedString? {
        guard let rep = item.representations.first(where: { $0.type == UTI.rtf }), rep.size < 300_000 else { return nil }
        let key = rep.blob as NSString
        if let cached = texts.object(forKey: key) { return cached }
        guard let data = store.blobs.read(rep.blob),
              let full = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        let text = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: 0, length: min(full.length, 2_000))))
        texts.setObject(text, forKey: key)
        return text
    }

    static func forget(_ hash: String) {
        images.removeObject(forKey: hash as NSString)
        texts.removeObject(forKey: hash as NSString)
    }
}

/// One card of the shelf.
struct CardView: View {
    let item: Item
    let index: Int
    @Bindable var model: ShelfModel
    let width: CGFloat
    let height: CGFloat
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var dropTargeted = false

    private var isSelected: Bool { model.selection.contains(item.id) }
    private var headerColor: Color { Color(nsColor: AppIcons.color(for: item.sourceBundleID)) }
    private var radius: CGFloat { model.compact ? 11 : 14 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ContentPreview(item: item, model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { footer }
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(-5)
                .opacity(isSelected ? 1 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5]))
                .opacity(dropTargeted ? 1 : 0)
        )
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onTapGesture {
            let event = NSApp.currentEvent
            if event?.clickCount == 2 {
                model.selection = [item.id]
                model.pasteSelection(plainText: false)
            } else {
                model.click(item, modifiers: event?.modifierFlags ?? [])
                model.controller?.updatePreview()
            }
        }
        .onDrag { dragProvider() }
        .onDrop(of: [.clippaItem], isTargeted: model.currentPinboard != nil ? $dropTargeted : .constant(false)) { providers in
            guard model.currentPinboard != nil, !model.isSearching else { return false }
            _ = providers.first?.loadDataRepresentation(for: .clippaItem) { data, _ in
                guard let data, let id = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { model.moveInPinboard(id, before: item.id) }
            }
            return true
        }
        .contextMenu { CardMenu(item: item, model: model) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if model.renamingID == item.id {
                    TextField(L("Title"), text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: model.compact ? 12 : 13, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit { model.rename(item.id, to: title) }
                        .onAppear {
                            title = item.title ?? ""
                            titleFocused = true
                        }
                } else {
                    Text(item.title ?? typeTitle)
                        .font(.system(size: model.compact ? 12 : 13, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { model.renamingID = item.id }
                }
                if !model.compact {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.relative(item.copiedAt, now: context.date))
                            .font(.system(size: 11))
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            badges
            Image(nsImage: AppIcons.icon(for: item.sourceBundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: model.compact ? 26 : 40, height: model.compact ? 26 : 40)
                .padding(.top, model.compact ? -2 : -3)
                .padding(.trailing, -4)
                .help(item.sourceAppName ?? "")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, model.compact ? 6 : 8)
        .frame(height: model.compact ? 32 : 50, alignment: .top)
        .background(headerColor)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if let pinboard = item.pinboardID.flatMap({ id in model.pinboards.first { $0.id == id } }), model.list == .history || model.isSearching {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(pinboard.color.color)
                    .padding(3)
                    .background(.white, in: Circle())
                    .help(L("Pinned to %@", pinboard.name))
            }
            switch item.keep {
            case .forever:
                Image(systemName: "infinity").font(.system(size: 10, weight: .bold))
                    .help(L("Kept forever"))
            case .until(let date):
                Image(systemName: "hourglass").font(.system(size: 10, weight: .bold))
                    .help(L("Deleted %@", Self.relative(date, now: Date())))
            case .automatic:
                EmptyView()
            }
        }
        .padding(.top, 2)
    }

    private var typeTitle: String {
        switch item.kind {
        case .file:
            let count = item.text.components(separatedBy: "\n").count
            return count == 1 ? L("File") : L("%lld Files", count)
        default:
            return item.kind.name
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 45 { return L("Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let info = infoText {
                Text(info)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(footerForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.showNumbers, index >= model.firstVisibleIndex, index < model.firstVisibleIndex + 9 {
                Text("\(ModifierChoice(rawValue: UserDefaults.standard.string(forKey: Pref.quickPasteModifier) ?? "")?.symbol ?? "⌘")\(index - model.firstVisibleIndex + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(footerBackground)
    }

    private var footerForeground: Color {
        item.kind == .color ? colorTextColor : Color.secondary
    }

    @ViewBuilder
    private var footerBackground: some View {
        if item.kind == .color || item.kind == .image || (item.kind == .link && item.linkImage != nil) {
            Color.clear
        } else {
            LinearGradient(colors: [Color(nsColor: .textBackgroundColor).opacity(0), Color(nsColor: .textBackgroundColor)],
                           startPoint: .top, endPoint: .center)
        }
    }

    private var colorTextColor: Color {
        guard let rgb = Classifier.rgb(item.text) else { return .primary }
        let luminance = 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue
        return luminance > 0.6 ? .black.opacity(0.7) : .white.opacity(0.9)
    }

    private var infoText: String? {
        switch item.kind {
        case .text:
            return L("%lld characters", item.text.count)
        case .link:
            return nil // the card already shows the title and the address
        case .image:
            guard let width = item.imageWidth, let height = item.imageHeight else { return nil }
            return "\(width) × \(height)"
        case .file:
            // The body already names the files; the footer gives the size of one.
            let paths = item.text.components(separatedBy: "\n")
            guard paths.count == 1,
                  let size = (try? FileManager.default.attributesOfItem(atPath: paths[0]))?[.size] as? Int64 else { return nil }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        case .color:
            guard let rgb = Classifier.rgb(item.text) else { return nil }
            return "RGB \(Int(rgb.red * 255)) \(Int(rgb.green * 255)) \(Int(rgb.blue * 255))"
        }
    }

    // MARK: Drag

    private func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let id = item.id
        provider.registerDataRepresentation(forTypeIdentifier: UTType.clippaItem.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        let store = model.store
        switch item.kind {
        case .image:
            if let rep = item.representations.first(where: { UTI.imageTypes.contains($0.type) }),
               let data = store.blobs.read(rep.blob) {
                provider.registerDataRepresentation(forTypeIdentifier: rep.type, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
        case .file:
            if let path = item.text.components(separatedBy: "\n").first {
                provider.registerObject(URL(fileURLWithPath: path) as NSURL, visibility: .all)
            }
        default:
            provider.registerObject(PasteboardWriter.plainText(of: item, store: store) as NSString, visibility: .all)
        }
        return provider
    }
}

/// The body of a card, by kind.
struct ContentPreview: View {
    let item: Item
    @Bindable var model: ShelfModel

    var body: some View {
        switch item.kind {
        case .text: textPreview
        case .link: linkPreview
        case .image: imagePreview
        case .file: filePreview
        case .color: colorPreview
        }
    }

    private var textPreview: some View {
        Text(displayText)
            .font(.system(size: model.compact ? 11 : 12, design: looksLikeCode ? .monospaced : .default))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 22)
            .clipped()
    }

    private var displayText: AttributedString {
        let raw = String(item.text.prefix(1_500))
        var result: AttributedString
        if let rich = PreviewCache.richText(of: item, store: model.store) {
            result = Self.cardStyled(rich)
        } else {
            result = AttributedString(raw)
        }
        // Highlight what the search matched.
        let terms = model.searchText.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        for term in terms {
            var searchRange = result.startIndex..<result.endIndex
            while let found = result[searchRange].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                result[found].backgroundColor = Color.yellow.opacity(0.55)
                searchRange = found.upperBound..<result.endIndex
            }
        }
        return result
    }

    /// Keeps bold, italic, underline and real colors of formatted text, but
    /// not its sizes or black/white text (unreadable in dark mode).
    private static func cardStyled(_ text: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var run = AttributedString(text.attributedSubstring(from: range).string)
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                var swiftFont = Font.system(size: 12)
                if traits.contains(.bold) { swiftFont = swiftFont.bold() }
                if traits.contains(.italic) { swiftFont = swiftFont.italic() }
                if traits.contains(.monoSpace) { swiftFont = .system(size: 11.5, design: .monospaced) }
                run.font = swiftFont
            }
            if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB), color.saturationComponent > 0.25 {
                run.foregroundColor = Color(nsColor: color)
            }
            if attributes[.underlineStyle] != nil { run.underlineStyle = .single }
            if attributes[.strikethroughStyle] != nil { run.strikethroughStyle = .single }
            result += run
        }
        return result
    }

    private var looksLikeCode: Bool { TextHeuristics.looksLikeCode(item.text) }

    private var linkPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Color.clear sets the size; the image fills it without
            // widening the card.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if let image = PreviewCache.image(item.linkImage, store: model.store) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: model.compact ? 22 : 34, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.linkTitle ?? Classifier.link(item.text)?.host ?? item.text)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Text(item.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 11)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var imagePreview: some View {
        ZStack {
            Color.primary.opacity(0.04)
            if let image = PreviewCache.image(item.thumbnail, store: model.store) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .padding(.bottom, 14)
            } else {
                Image(systemName: "photo").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            }
        }
    }

    private var filePreview: some View {
        let paths = item.text.components(separatedBy: "\n")
        return VStack(spacing: 8) {
            if let image = PreviewCache.image(item.thumbnail, store: model.store) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 10)
            } else {
                ZStack {
                    ForEach(Array(paths.prefix(3).enumerated().reversed()), id: \.offset) { offset, path in
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: model.compact ? 44 : 72, height: model.compact ? 44 : 72)
                            .offset(x: CGFloat(offset) * 10, y: CGFloat(offset) * -6)
                    }
                }
            }
            if !model.compact {
                Text(paths.count == 1 ? (paths[0] as NSString).lastPathComponent : L("%lld files", paths.count))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 22)
    }

    private var colorPreview: some View {
        let rgb = Classifier.rgb(item.text) ?? (0.5, 0.5, 0.5)
        let luminance = 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue
        return ZStack {
            Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            Text(item.text)
                .font(.system(size: model.compact ? 14 : 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(luminance > 0.6 ? Color.black.opacity(0.75) : Color.white)
        }
    }
}
