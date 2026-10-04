@testable import ClippaCore
import XCTest

final class ClassifierTests: XCTestCase {
    func testHexColorsFollowPasteRules() {
        XCTAssertEqual(Classifier.hexColor("#1A2B3C"), "#1A2B3C")
        XCTAssertEqual(Classifier.hexColor("1a2b3c"), "#1A2B3C")
        XCTAssertEqual(Classifier.hexColor("  #e8f500\n"), "#E8F500")
        XCTAssertNil(Classifier.hexColor("235442"), "a six-digit code stays text")
        XCTAssertEqual(Classifier.hexColor("#235442"), "#235442", "with # it is a color")
        XCTAssertNil(Classifier.hexColor("#FFF"))
        XCTAssertNil(Classifier.hexColor("color #1A2B3C"))
        XCTAssertNil(Classifier.hexColor("rgb(1,2,3)"))
    }

    func testLinks() {
        XCTAssertNotNil(Classifier.link("https://pasteapp.io/help"))
        XCTAssertNotNil(Classifier.link("mailto:someone@example.com"))
        XCTAssertNil(Classifier.link("see https://example.com"))
        XCTAssertNil(Classifier.link("example.com"))
        XCTAssertNil(Classifier.link("https://"))
        XCTAssertEqual(Classifier.kind(forText: "https://example.com"), .link)
        XCTAssertEqual(Classifier.kind(forText: "#A0B1C2"), .color)
        XCTAssertEqual(Classifier.kind(forText: "hello"), .text)
    }
}

/// Helpers shared by the store tests.
class StoreTestCase: XCTestCase {
    var directories: [URL] = []

    func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clippa-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    func makeStore(device: String = "mac-a", directory: URL? = nil) throws -> ClippaStore {
        try ClippaStore(directory: directory ?? makeDirectory(), deviceID: device, deviceName: device.uppercased())
    }

    override func tearDownWithError() throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }

    @discardableResult
    func saveText(_ text: String, in store: ClippaStore, app: String = "com.apple.Safari",
                  at date: Date = Date()) throws -> Item {
        try store.save(CapturedContent(kind: Classifier.kind(forText: text), text: text, identity: text,
                                       representations: [CapturedRepresentation(index: 0, type: UTI.plainText, data: Data(text.utf8))],
                                       sourceBundleID: app, sourceAppName: app.components(separatedBy: ".").last),
                       at: date)
    }
}

final class StoreTests: StoreTestCase {
    func testCopyingTheSameTextMovesItToTheFront() throws {
        let store = try makeStore()
        let first = try saveText("alpha", in: store, at: Date(timeIntervalSinceNow: -100))
        try saveText("beta", in: store, at: Date(timeIntervalSinceNow: -50))
        let again = try saveText("alpha", in: store)
        XCTAssertEqual(first.id, again.id)
        let items = try store.items(matching: ItemQuery())
        XCTAssertEqual(items.map(\.text), ["alpha", "beta"])
        XCTAssertEqual(try store.totalItemCount(), 2)
    }

    func testSameContentGetsTheSameIDOnEveryMac() throws {
        let a = try saveText("shared text", in: try makeStore(device: "mac-a"))
        let b = try saveText("shared text", in: try makeStore(device: "mac-b"))
        XCTAssertEqual(a.id, b.id)
    }

    func testSearchFindsPartsOfWordsAndShortTerms() throws {
        let store = try makeStore()
        try saveText("Robotics workshop rental", in: store)
        try saveText("Perché no", in: store, app: "com.apple.Notes")
        try saveText("ab cd", in: store)

        XCTAssertEqual(try store.items(matching: ItemQuery(search: "bot")).count, 1)
        XCTAssertEqual(try store.items(matching: ItemQuery(search: "BOTICS rent")).count, 1)
        XCTAssertEqual(try store.items(matching: ItemQuery(search: "perche")).count, 1, "accents are ignored")
        XCTAssertEqual(try store.items(matching: ItemQuery(search: "cd")).count, 1, "two-letter terms work")
        XCTAssertEqual(try store.items(matching: ItemQuery(search: "Notes")).count, 1, "app names are searchable")
        XCTAssertEqual(try store.items(matching: ItemQuery(search: "zzz")).count, 0)
        XCTAssertEqual(try store.items(matching: ItemQuery(search: "50%")).count, 0, "LIKE wildcards are escaped")
    }

    func testFilters() throws {
        let store = try makeStore()
        try saveText("https://example.com", in: store)
        try saveText("#E8F500", in: store, app: "com.figma.Desktop")
        try saveText("plain words", in: store)
        XCTAssertEqual(try store.items(matching: ItemQuery(kinds: [.link])).map(\.kind), [.link])
        XCTAssertEqual(try store.items(matching: ItemQuery(kinds: [.color])).first?.text, "#E8F500")
        XCTAssertEqual(try store.items(matching: ItemQuery(apps: ["com.figma.Desktop"])).count, 1)
        XCTAssertEqual(try store.items(matching: ItemQuery(date: .today)).count, 3)
        XCTAssertEqual(try store.items(matching: ItemQuery(date: .yesterday)).count, 0)
        XCTAssertEqual(try store.sourceApps().first?.bundleID, "com.apple.Safari")
    }

    func testPinboardsKeepTheirOrderAndSearchCoversThem() throws {
        let store = try makeStore()
        let board = try store.createPinboard(name: "Snippets", color: .orange)
        let one = try saveText("one", in: store)
        let two = try saveText("two", in: store)
        try store.pin([one.id], to: board.id)
        try store.pin([two.id], to: board.id)
        // Newly pinned items go to the front.
        XCTAssertEqual(try store.items(matching: ItemQuery(list: .pinboard(board.id))).map(\.text), ["two", "one"])
        try store.move(two.id, toIndex: 1, in: board.id)
        XCTAssertEqual(try store.items(matching: ItemQuery(list: .pinboard(board.id))).map(\.text), ["one", "two"])
        // Pinned items stay in the history too.
        XCTAssertEqual(try store.items(matching: ItemQuery()).count, 2)
        // A search started inside a pinboard looks everywhere, unless asked not to.
        try saveText("three", in: store)
        XCTAssertEqual(try store.items(matching: ItemQuery(list: .pinboard(board.id), search: "three")).count, 1)
        XCTAssertEqual(try store.items(matching: ItemQuery(list: .pinboard(board.id), search: "three", searchAllLists: false)).count, 0)
        XCTAssertEqual(try store.pinboardItemCounts()[board.id], 2)

        try store.deletePinboard(id: board.id)
        XCTAssertEqual(try store.pinboards().count, 0)
        XCTAssertEqual(try store.totalItemCount(), 1, "deleting a pinboard deletes its items, like Paste")
    }

    func testDeleteAndUndo() throws {
        let store = try makeStore()
        let item = try saveText("keep me", in: store)
        let removed = try store.delete(ids: [item.id])
        XCTAssertEqual(try store.totalItemCount(), 0)
        try store.restore(removed)
        XCTAssertEqual(try store.item(id: item.id)?.text, "keep me")
        XCTAssertEqual(try store.items(matching: ItemQuery(search: "keep")).count, 1, "search index restored")
    }

    func testRenameAndCreatedItemsAreSearchable() throws {
        let store = try makeStore()
        let item = try saveText("x = 1", in: store)
        try store.setTitle("Assignment", for: item.id)
        XCTAssertEqual(try store.items(matching: ItemQuery(search: "assign")).first?.id, item.id)
        try store.setTitle("  ", for: item.id)
        XCTAssertNil(try store.item(id: item.id)?.title)

        let board = try store.createPinboard(name: "Templates", color: .green)
        let note = try store.createTextItem("Dear customer", pinboardID: board.id)
        XCTAssertFalse(note.inHistory, "items created in a pinboard are not in the history")
        XCTAssertEqual(try store.items(matching: ItemQuery()).count, 1)
        XCTAssertEqual(try store.items(matching: ItemQuery(list: .pinboard(board.id))).first?.text, "Dear customer")
    }

    func testUnpinningAnItemThatLeftTheHistoryDeletesIt() throws {
        let store = try makeStore()
        let board = try store.createPinboard(name: "B", color: .blue)
        let note = try store.createTextItem("only in the pinboard", pinboardID: board.id)
        try store.pin([note.id], to: nil)
        XCTAssertNil(try store.item(id: note.id))
    }

    func testGarbageCollectionKeepsReferencedBlobs() throws {
        let store = try makeStore()
        let kept = try saveText("kept", in: store)
        let gone = try saveText("gone", in: store)
        try store.delete(ids: [gone.id])
        XCTAssertEqual(try store.collectGarbage(), 1)
        XCTAssertTrue(store.blobs.exists(kept.representations[0].blob))
        XCTAssertFalse(store.blobs.exists(gone.representations[0].blob))
    }
}

final class RetentionTests: StoreTestCase {
    func testKeepHistoryAndPerItemRules() throws {
        let store = try makeStore()
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let recent = try saveText("recent", in: store, at: now.addingTimeInterval(-86_400))
        let oldPlain = try saveText("old plain", in: store, at: old)
        let oldPinned = try saveText("old pinned", in: store, at: old)
        let oldForever = try saveText("old forever", in: store, at: old)
        let soon = try saveText("delete soon", in: store, at: now.addingTimeInterval(-60))
        let board = try store.createPinboard(name: "P", color: .red)
        try store.pin([oldPinned.id, soon.id], to: board.id)
        try store.setKeep(.forever, for: [oldForever.id])
        try store.setKeep(.until(now.addingTimeInterval(-1)), for: [soon.id])

        XCTAssertEqual(try store.countExpiring(under: .month, now: now), 1)
        XCTAssertEqual(try store.countExpiring(under: .forever, now: now), 0)

        let deleted = try store.purgeExpired(retention: .month, now: now)
        XCTAssertEqual(deleted, 2, "the old un-pinned item and the expired one")
        XCTAssertNotNil(try store.item(id: recent.id))
        XCTAssertNil(try store.item(id: oldPlain.id))
        XCTAssertNil(try store.item(id: soon.id), "an explicit date wins over pinning")
        XCTAssertNotNil(try store.item(id: oldForever.id))
        let pinned = try XCTUnwrap(try store.item(id: oldPinned.id))
        XCTAssertFalse(pinned.inHistory, "pinned items leave the history but stay in their pinboard")
        XCTAssertEqual(try store.items(matching: ItemQuery()).map(\.text).sorted(), ["old forever", "recent"])
    }

    func testForeverKeepsEverything() throws {
        let store = try makeStore()
        try saveText("ancient", in: store, at: Date(timeIntervalSinceNow: -3_000 * 86_400))
        XCTAssertEqual(try store.purgeExpired(retention: .forever), 0)
        XCTAssertEqual(try store.totalItemCount(), 1)
    }

    func testExpiryDates() throws {
        let copied = Date(timeIntervalSince1970: 1_000_000)
        var item = Item(kind: .text, createdAt: copied, text: "x", contentHash: "h", deviceID: "d", deviceName: "D")
        XCTAssertEqual(item.expiryDate(retention: .day), copied.addingTimeInterval(86_400))
        XCTAssertNil(item.expiryDate(retention: .forever))
        item.pinboardID = "board"
        XCTAssertNil(item.expiryDate(retention: .day))
        item.keep = .until(copied)
        XCTAssertEqual(item.expiryDate(retention: .day), copied)
        item.keep = .forever
        XCTAssertNil(item.expiryDate(retention: .day))

        let now = Date()
        XCTAssertEqual(KeepChoice.hour.rule(now: now), .until(now.addingTimeInterval(3_600)))
        XCTAssertEqual(KeepChoice.automatic.rule(now: now), .automatic)
    }

    func testEraseHistoryKeepsPinnedAndForever() throws {
        let store = try makeStore()
        let board = try store.createPinboard(name: "P", color: .red)
        let pinned = try saveText("pinned", in: store)
        let forever = try saveText("forever", in: store)
        try saveText("plain", in: store)
        try store.pin([pinned.id], to: board.id)
        try store.setKeep(.forever, for: [forever.id])
        try store.eraseHistory()
        XCTAssertEqual(try store.items(matching: ItemQuery()).map(\.text), ["forever"])
        XCTAssertEqual(try store.items(matching: ItemQuery(list: .pinboard(board.id))).map(\.text), ["pinned"])
    }
}
