import AppKit
import ClippaCore
import LinkPresentation

/// Work done after an item is saved, in the background: text recognition
/// in images and link previews (title and picture of a web page).
@MainActor
final class Enricher {
    private let store: ClippaStore
    private let onUpdate: (String) -> Void
    private let queue = DispatchQueue(label: "clippa.enricher", qos: .utility)

    init(store: ClippaStore, onUpdate: @escaping (String) -> Void) {
        self.store = store
        self.onUpdate = onUpdate
    }

    func process(_ item: Item) {
        switch item.kind {
        case .image where item.ocrText == nil && UserDefaults.standard.bool(forKey: Pref.recognizeText):
            recognizeText(in: item)
        case .link where item.linkTitle == nil && UserDefaults.standard.bool(forKey: Pref.fetchLinkPreviews):
            fetchPreview(for: item)
        default:
            break
        }
    }

    private func recognizeText(in item: Item) {
        guard let rep = item.representations.first(where: { UTI.imageTypes.contains($0.type) }) else { return }
        let store = store
        queue.async { [weak self] in
            guard let data = store.blobs.read(rep.blob), let text = ImageTools.recognizeText(in: data) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // The item may have changed meanwhile: only fill this field.
                try? self.store.modify(ids: [item.id]) { $0.ocrText = text }
                self.onUpdate(item.id)
            }
        }
    }

    private func fetchPreview(for item: Item) {
        guard let url = Classifier.link(item.text), url.scheme?.hasPrefix("http") == true else { return }
        let provider = LPMetadataProvider()
        provider.timeout = 10
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            guard let metadata else { return }
            let title = metadata.title
            let imageProvider = metadata.imageProvider ?? metadata.iconProvider
            let finish: (Data?) -> Void = { imageData in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let blob = imageData.flatMap { ImageTools.thumbnail(of: $0, maxPixel: 600) }
                        .flatMap { try? self.store.blobs.write($0) }
                    try? self.store.modify(ids: [item.id]) {
                        $0.linkTitle = title ?? url.host
                        $0.linkImage = blob
                    }
                    self.onUpdate(item.id)
                }
            }
            guard let imageProvider, imageProvider.canLoadObject(ofClass: NSImage.self) else {
                finish(nil)
                return
            }
            imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                finish(data)
            }
        }
    }
}
