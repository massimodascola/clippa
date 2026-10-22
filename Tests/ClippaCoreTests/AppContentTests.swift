@testable import ClippaCore
import XCTest

/// Stands in for Final Cut Pro's clip objects: archived with a "displayName".
@objc(ClippaTestsFakeClip)
private final class FakeClip: NSObject, NSCoding {
    let displayName: String
    let children: [FakeClip]

    init(_ name: String, _ children: [FakeClip] = []) {
        displayName = name
        self.children = children
    }

    func encode(with coder: NSCoder) {
        coder.encode(displayName, forKey: "displayName")
        coder.encode(children as NSArray, forKey: "containedItems")
    }

    required init?(coder: NSCoder) { nil }
}

final class AppContentTests: StoreTestCase {
    private func finalCutData(_ root: FakeClip) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("FFAnchoredSequence", for: FakeClip.self)
        archiver.encode(root, forKey: "root")
        archiver.finishEncoding()
        let outer: [String: Any] = ["ffpasteboardobject": archiver.encodedData,
                                    "ffpasteboardcopiedtypes": ["anchoredObject": ["count": 2]]]
        return try PropertyListSerialization.data(fromPropertyList: outer, format: .binary, options: 0)
    }

    func testFinalCutClipNames() throws {
        let data = try finalCutData(FakeClip("Timeline", [FakeClip("Intro"), FakeClip("B-roll"), FakeClip("Intro")]))
        XCTAssertEqual(AppContent.clipNames(in: data), ["Timeline", "Intro", "B-roll"])
        let text = AppContent.describe(types: [AppContent.finalCutPro], data: { _ in data }, appName: "Final Cut Pro")
        XCTAssertEqual(text, "Final Cut Pro\nTimeline\nIntro\nB-roll")
    }

    func testUnknownDataGivesNoNames() {
        XCTAssertEqual(AppContent.clipNames(in: Data("not a property list".utf8)), [])
        XCTAssertEqual(AppContent.describe(types: ["com.example.private"], data: { _ in Data([1, 2]) }, appName: "Example"),
                       "Example")
        XCTAssertNil(AppContent.knownApp(in: ["public.utf8-plain-text"]))
        XCTAssertEqual(AppContent.knownApp(in: ["public.utf8-plain-text", AppContent.finalCutPro]), "Final Cut Pro")
    }

    /// App content is saved byte for byte and comes back the same.
    func testAppContentRoundTrip() throws {
        let store = try makeStore()
        let data = try finalCutData(FakeClip("Timeline"))
        let capture = CapturedContent(kind: .other, text: "Final Cut Pro\nTimeline", identity: BlobStore.hash(data),
                                      representations: [CapturedRepresentation(index: 0, type: AppContent.finalCutPro, data: data)])
        let item = try store.save(capture)
        let saved = try XCTUnwrap(try store.item(id: item.id))
        XCTAssertEqual(saved.kind, .other)
        XCTAssertEqual(saved.representations.first?.type, AppContent.finalCutPro)
        XCTAssertEqual(store.blobs.read(try XCTUnwrap(saved.representations.first).blob), data)
    }

    /// A kind added by a newer Clippa must not stop sync on this one.
    func testUnknownKindDecodesAsOther() throws {
        let decoded = try JSONDecoder().decode([ItemKind].self, from: Data(#"["text","hologram","other"]"#.utf8))
        XCTAssertEqual(decoded, [.text, .other, .other])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(ItemKind.other), as: UTF8.self), #""other""#)
    }
}
