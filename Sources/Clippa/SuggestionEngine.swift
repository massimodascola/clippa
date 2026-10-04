import AppKit
import ApplicationServices
import ClippaCore
import NaturalLanguage
import ScreenCaptureKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests what you are about to paste, from what you are working on.
/// Everything runs on this Mac: the context is read when the shelf opens,
/// used once and never stored.
///
/// 1. Context: the app in front, its window title and the text around the
///    cursor (through Accessibility, already granted for pasting); with
///    "Use screen content" on, also the text visible in its window.
/// 2. A quick ranking: what you pasted into this app before, the kinds of
///    items it usually gets, similarity with the context, recency.
/// 3. With Apple Intelligence (macOS 26 and later), the on-device model
///    re-orders the best candidates.
@MainActor
final class SuggestionEngine {
    private let store: ClippaStore
    private let queue = DispatchQueue(label: "clippa.suggestions", qos: .userInitiated)
    private var generation = 0

    init(store: ClippaStore) {
        self.store = store
    }

    struct Context: Sendable {
        var bundleID: String?
        var appName: String?
        var windowTitle: String?
        var text: String

        var isEmpty: Bool { text.isEmpty && (windowTitle ?? "").isEmpty }
    }

    /// Calls `update` with a first ranking, then (if the on-device model is
    /// available) with a refined one. `done` is true on the last call.
    func suggest(for app: NSRunningApplication?, update: @escaping ([Item], _ done: Bool) -> Void) {
        generation += 1
        let current = generation
        let store = store
        let pid = app?.processIdentifier
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName
        let useScreen = UserDefaults.standard.bool(forKey: Pref.useScreenContent) && Permissions.canReadScreen
        let ignored = Set(Pref.ignoredAppIDs)

        Task.detached(priority: .userInitiated) {
            var context = Context(bundleID: bundleID, appName: appName, text: "")
            // Apps excluded in Privacy are never read.
            if let pid, let bundleID, !ignored.contains(bundleID) {
                context = Self.accessibilityContext(pid: pid, bundleID: bundleID, appName: appName)
                if useScreen, let screenText = await Self.screenText(pid: pid) {
                    context.text = String((context.text + "\n" + screenText).prefix(4_000))
                }
            }
            let ranked = Self.rank(store: store, context: context)
            await MainActor.run { [weak self] in
                guard let self, self.generation == current else { return }
                update(ranked.map(\.item), !Self.modelAvailable)
            }
            guard Self.modelAvailable, !ranked.isEmpty else { return }
            let refined = await Self.refine(Array(ranked.prefix(24)), context: context)
            await MainActor.run { [weak self] in
                guard let self, self.generation == current else { return }
                let chosen = refined ?? []
                let rest = ranked.map(\.item).filter { item in !chosen.contains { $0.id == item.id } }
                update(chosen + rest, true)
            }
        }
    }

    // MARK: - Context

    nonisolated private static func accessibilityContext(pid: pid_t, bundleID: String, appName: String?) -> Context {
        var context = Context(bundleID: bundleID, appName: appName, text: "")
        guard AXIsProcessTrusted() else { return context }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) {
            context.windowTitle = attribute(window, kAXTitleAttribute)
        }
        if let element: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) {
            // Password fields never give suggestions.
            let subrole: String? = attribute(element, kAXSubroleAttribute)
            guard subrole != (kAXSecureTextFieldSubrole as String) else { return context }
            var parts: [String] = []
            if let value: String = attribute(element, kAXValueAttribute) { parts.append(String(value.suffix(2_500))) }
            if let placeholder: String = attribute(element, kAXPlaceholderValueAttribute) { parts.append(placeholder) }
            if let title: String = attribute(element, kAXTitleAttribute) { parts.append(title) }
            if let description: String = attribute(element, kAXDescriptionAttribute) { parts.append(description) }
            context.text = parts.joined(separator: "\n")
        }
        return context
    }

    nonisolated private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    nonisolated private static func screenText(pid: pid_t) async -> String? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              let png = ImageTools.png(image) else { return nil }
        return ImageTools.recognizeText(in: png)
    }

    // MARK: - Ranking

    struct Scored: Sendable {
        var item: Item
        var score: Double
    }

    nonisolated static func rank(store: ClippaStore, context: Context, now: Date = Date()) -> [Scored] {
        var candidates = (try? store.items(matching: ItemQuery(list: .history, limit: 300))) ?? []
        for pinboard in (try? store.pinboards()) ?? [] {
            candidates += (try? store.items(matching: ItemQuery(list: .pinboard(pinboard.id), limit: 60))) ?? []
        }
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.id).inserted }

        let pasteCounts = context.bundleID.flatMap { try? store.pasteCounts(into: $0) } ?? [:]
        let kindCounts = context.bundleID.flatMap { try? store.pastedKinds(into: $0) } ?? [:]
        let totalKinds = Double(kindCounts.values.reduce(0, +))
        let contextText = [context.windowTitle ?? "", context.text].joined(separator: "\n")
        let similarity = Similarity(context: contextText)

        let scored = candidates.map { item -> Scored in
            var score = 0.0
            if let count = pasteCounts[item.id] { score += 3 * log2(1 + Double(count)) }
            if totalKinds > 0 { score += 2 * Double(kindCounts[item.kind] ?? 0) / totalKinds }
            score += 4 * similarity.score(for: [item.title, item.text, item.linkTitle, item.ocrText].compactMap { $0 }.joined(separator: " "))
            let age = now.timeIntervalSince(item.copiedAt)
            score += 1.5 * exp(-age / 86_400)
            if item.isPinned { score += 0.3 }
            return Scored(item: item, score: score)
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(40))
    }

    /// How close a text is to the context: sentence embeddings when the
    /// language has them, shared words otherwise.
    struct Similarity {
        private let embedding: NLEmbedding?
        private let contextVector: [Double]?
        private let contextWords: Set<String>

        init(context: String) {
            let trimmed = String(context.suffix(1_500))
            contextWords = Self.words(trimmed)
            let language = NLLanguageRecognizer.dominantLanguage(for: trimmed) ?? .english
            embedding = trimmed.isEmpty ? nil : NLEmbedding.sentenceEmbedding(for: language)
            contextVector = embedding?.vector(for: trimmed)
        }

        func score(for text: String) -> Double {
            let sample = String(text.prefix(400))
            guard !sample.isEmpty else { return 0 }
            if let embedding, let contextVector, let vector = embedding.vector(for: sample) {
                let cosine = Self.cosine(contextVector, vector)
                return max(0, (cosine - 0.35) / 0.65)
            }
            guard !contextWords.isEmpty else { return 0 }
            let words = Self.words(sample)
            guard !words.isEmpty else { return 0 }
            return Double(words.intersection(contextWords).count) / Double(min(words.count, contextWords.count))
        }

        static func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 })
        }

        static func cosine(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count else { return 0 }
            var dot = 0.0, normA = 0.0, normB = 0.0
            for index in a.indices {
                dot += a[index] * b[index]
                normA += a[index] * a[index]
                normB += b[index] * b[index]
            }
            return normA > 0 && normB > 0 ? dot / (normA.squareRoot() * normB.squareRoot()) : 0
        }
    }

    // MARK: - Apple Intelligence

    nonisolated static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    nonisolated private static func refine(_ candidates: [Scored], context: Context) async -> [Item]? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        var list = ""
        for (index, candidate) in candidates.enumerated() {
            let item = candidate.item
            let body = [item.title, item.linkTitle, item.kind == .image ? item.ocrText : item.text]
                .compactMap { $0 }.joined(separator: " — ")
                .replacingOccurrences(of: "\n", with: " ")
            list += "\(index + 1). [\(item.kind.rawValue)] \(String(body.prefix(140)))\n"
        }
        let prompt = """
        The user is about to paste into \(context.appName ?? "an app")\
        \(context.windowTitle.map { " (window: \($0))" } ?? "").
        Text near the cursor:
        \(String(context.text.suffix(1_200)))

        Clipboard items:
        \(list)
        Which items will the user most likely paste now? Reply only with up to 8 item numbers, best first, separated by commas.
        """
        let session = LanguageModelSession(instructions: "You rank clipboard items by how useful they are for the user's current task. You answer with numbers only.")
        guard let response = try? await session.respond(to: prompt) else { return nil }
        var chosen: [Item] = []
        for token in response.content.split(whereSeparator: { !$0.isNumber }) {
            guard let number = Int(token), candidates.indices.contains(number - 1) else { continue }
            let item = candidates[number - 1].item
            if !chosen.contains(where: { $0.id == item.id }) { chosen.append(item) }
        }
        return chosen.isEmpty ? nil : chosen
        #else
        return nil
        #endif
    }
}
