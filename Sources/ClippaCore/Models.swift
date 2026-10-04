import Foundation

/// What kind of content an item holds. Drives the card layout and the
/// "type" search filter.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case text
    case link
    case image
    case file
    case color
}

/// One pasteboard type of a copied item, e.g. the RTF or the PNG data.
/// The bytes live in the blob store under `blob` (their SHA-256).
public struct Representation: Codable, Hashable, Sendable {
    /// Index of the pasteboard item it belongs to. Copying three files puts
    /// three items on the pasteboard; pasting must restore all three.
    public var index: Int
    /// Uniform type identifier, e.g. "public.utf8-plain-text".
    public var type: String
    public var blob: String
    public var size: Int

    public init(index: Int, type: String, blob: String, size: Int) {
        self.index = index
        self.type = type
        self.blob = blob
        self.size = size
    }
}

/// How long a single item is kept, on top of the global Keep History setting.
public enum KeepRule: Hashable, Codable, Sendable {
    /// Follows Settings → Keep History (pinned items never expire).
    case automatic
    /// Never deleted automatically.
    case forever
    /// Deleted at this date, pinned or not.
    case until(Date)

    var storedMode: String {
        switch self {
        case .automatic: return "auto"
        case .forever: return "forever"
        case .until: return "until"
        }
    }

    var storedDate: Date? {
        if case .until(let date) = self { return date }
        return nil
    }

    static func stored(mode: String, date: Date?) -> KeepRule {
        switch mode {
        case "forever": return .forever
        case "until": return date.map { .until($0) } ?? .automatic
        default: return .automatic
        }
    }
}

/// A saved copy: one card in the shelf.
public struct Item: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: ItemKind
    /// First time this content was copied.
    public var createdAt: Date
    /// Last time it was copied (or pasted back): orders the history and
    /// drives the retention.
    public var copiedAt: Date
    /// Label chosen by the user (Rename).
    public var title: String?
    /// Plain text used for previews and search: the text itself, the URL,
    /// the hex code, or the file names.
    public var text: String
    /// Text recognized inside an image.
    public var ocrText: String?
    public var linkTitle: String?
    /// Blob of the link preview image.
    public var linkImage: String?
    /// Blob of a small PNG used by the card (images only).
    public var thumbnail: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var byteSize: Int
    public var contentHash: String
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var deviceID: String
    public var deviceName: String
    public var pinboardID: String?
    public var pinOrder: Double
    /// False once a pinned item has left Clipboard History (it aged out, or
    /// the history was erased) or when it was created inside a pinboard.
    public var inHistory: Bool
    public var keep: KeepRule
    public var representations: [Representation]
    /// Last change of any field, for sync (last writer wins).
    public var modifiedAt: Date
    public var modifiedBy: String

    public init(id: String = UUID().uuidString, kind: ItemKind, createdAt: Date = Date(),
                copiedAt: Date? = nil, title: String? = nil, text: String,
                ocrText: String? = nil, linkTitle: String? = nil, linkImage: String? = nil,
                thumbnail: String? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil,
                byteSize: Int = 0, contentHash: String,
                sourceBundleID: String? = nil, sourceAppName: String? = nil,
                deviceID: String, deviceName: String, pinboardID: String? = nil,
                pinOrder: Double = 0, inHistory: Bool = true, keep: KeepRule = .automatic,
                representations: [Representation] = [], modifiedAt: Date? = nil,
                modifiedBy: String? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.copiedAt = copiedAt ?? createdAt
        self.title = title
        self.text = text
        self.ocrText = ocrText
        self.linkTitle = linkTitle
        self.linkImage = linkImage
        self.thumbnail = thumbnail
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pinboardID = pinboardID
        self.pinOrder = pinOrder
        self.inHistory = inHistory
        self.keep = keep
        self.representations = representations
        self.modifiedAt = modifiedAt ?? createdAt
        self.modifiedBy = modifiedBy ?? deviceID
    }

    public var isPinned: Bool { pinboardID != nil }

    /// Every blob this item points to.
    public var blobHashes: [String] {
        representations.map(\.blob) + [thumbnail, linkImage].compactMap { $0 }
    }

    /// True when the content carries formatting (RTF or HTML).
    public var isRichText: Bool {
        representations.contains { $0.type == UTType.rtf || $0.type == UTType.html || $0.type == UTType.rtfd }
    }
}

/// A named, colored collection of items that never expire.
public struct Pinboard: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var color: PinboardColor
    public var sortOrder: Double
    public var modifiedAt: Date
    public var modifiedBy: String

    public init(id: String = UUID().uuidString, name: String, color: PinboardColor,
                sortOrder: Double = 0, modifiedAt: Date = Date(), modifiedBy: String) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
    }
}

/// Pinboard colors, stored as their raw value. The UI maps them to system colors.
public enum PinboardColor: Int, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray
}

/// A record that something was deleted, so the deletion reaches other Macs.
public struct Tombstone: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case item, pinboard }
    public var id: String
    public var kind: Kind
    public var deletedAt: Date
    public var deletedBy: String

    public init(id: String, kind: Kind, deletedAt: Date, deletedBy: String) {
        self.id = id
        self.kind = kind
        self.deletedAt = deletedAt
        self.deletedBy = deletedBy
    }
}

/// Uniform type identifiers as strings, so ClippaCore does not depend on
/// UniformTypeIdentifiers or AppKit.
public enum UTType {
    public static let plainText = "public.utf8-plain-text"
    public static let string = "NSStringPboardType"
    public static let rtf = "public.rtf"
    public static let rtfd = "com.apple.flat-rtfd"
    public static let html = "public.html"
    public static let url = "public.url"
    public static let fileURL = "public.file-url"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let jpeg = "public.jpeg"
    public static let heic = "public.heic"
    public static let pdf = "com.adobe.pdf"
    /// nspasteboard.org conventions, honored by password managers and others.
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let transient = "org.nspasteboard.TransientType"
    public static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
    public static let source = "org.nspasteboard.source"

    public static let imageTypes: Set<String> = [png, tiff, jpeg, heic, "com.compuserve.gif", "public.webp"]
}
