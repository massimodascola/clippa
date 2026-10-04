@testable import ClippaCore
import XCTest

final class SyncTests: StoreTestCase {
    private func engine(_ store: ClippaStore, folder: URL, mode: JournalMode = .everything) -> SyncEngine {
        store.journalMode = mode
        return SyncEngine(store: store, root: folder, mode: mode, retention: .forever)
    }

    func testItemsPinboardsAndDeletionsTravel() throws {
        let folder = try makeDirectory()
        let a = try makeStore(device: "mac-a")
        let b = try makeStore(device: "mac-b")
        let syncA = engine(a, folder: folder)
        let syncB = engine(b, folder: folder)

        let board = try a.createPinboard(name: "Work", color: .purple)
        let note = try saveText("meeting notes", in: a)
        try saveText("https://example.com", in: a)
        try a.pin([note.id], to: board.id)

        XCTAssertGreaterThan(try syncA.sync().exported, 0)
        let report = try syncB.sync()
        XCTAssertEqual(try b.totalItemCount(), 2)
        XCTAssertGreaterThan(report.imported, 0)
        XCTAssertEqual(try b.pinboards().map(\.name), ["Work"])
        XCTAssertEqual(try b.items(matching: ItemQuery(list: .pinboard(board.id))).map(\.text), ["meeting notes"])
        XCTAssertNotNil(b.blobs.read(note.representations[0].blob), "the data travels with the item")

        // B deletes, A follows.
        try b.delete(ids: [note.id])
        try syncB.sync()
        try syncA.sync()
        XCTAssertNil(try a.item(id: note.id))

        // Changes made on A don't come back to A.
        XCTAssertEqual(try syncA.sync().imported, 0)
    }

    func testNewestChangeWins() throws {
        let folder = try makeDirectory()
        let a = try makeStore(device: "mac-a")
        let b = try makeStore(device: "mac-b")
        let syncA = engine(a, folder: folder)
        let syncB = engine(b, folder: folder)
        let item = try saveText("draft", in: a)
        try syncA.sync()
        try syncB.sync()

        let now = Date()
        try a.modify(ids: [item.id], at: now) { $0.title = "From A" }
        try b.modify(ids: [item.id], at: now.addingTimeInterval(5)) { $0.title = "From B" }
        try syncA.sync()
        try syncB.sync()
        try syncA.sync()
        XCTAssertEqual(try a.item(id: item.id)?.title, "From B")
        XCTAssertEqual(try b.item(id: item.id)?.title, "From B")
    }

    func testPinboardsOnlyKeepsTheHistoryOnThisMac() throws {
        let folder = try makeDirectory()
        let work = try makeStore(device: "work-mac")
        let home = try makeStore(device: "home-mac")
        let syncWork = engine(work, folder: folder, mode: .pinboardsOnly)
        let syncHome = engine(home, folder: folder)

        let board = try work.createPinboard(name: "Shared", color: .teal)
        try saveText("private work text", in: work)
        let pinned = try saveText("shared snippet", in: work)
        try work.pin([pinned.id], to: board.id)
        try syncWork.sync()
        try syncHome.sync()
        XCTAssertEqual(try home.items(matching: ItemQuery(search: "")).map(\.text), ["shared snippet"])

        // The work Mac doesn't take in the home history either.
        try saveText("home history", in: home)
        try syncHome.sync()
        try syncWork.sync()
        XCTAssertTrue(try work.items(matching: ItemQuery(search: "home history")).isEmpty)
    }

    func testCompactionLetsANewMacCatchUp() throws {
        let folder = try makeDirectory()
        let a = try makeStore(device: "mac-a")
        let syncA = engine(a, folder: folder)
        syncA.compactionThreshold = 3
        for index in 0..<5 {
            try saveText("item \(index)", in: a)
            try syncA.sync()
        }
        let removed = try saveText("item 0", in: a)
        try a.delete(ids: [removed.id])
        try syncA.sync()
        try syncA.compact()

        let files = try FileManager.default.contentsOfDirectory(
            atPath: folder.appendingPathComponent("devices/mac-a/changes").path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix("-s.json"))

        let c = try makeStore(device: "mac-c")
        try engine(c, folder: folder).sync()
        XCTAssertEqual(try c.totalItemCount(), 4)
        XCTAssertNil(try c.item(id: removed.id))
    }

    func testFullExportOnFirstSync() throws {
        let folder = try makeDirectory()
        let a = try makeStore(device: "mac-a")
        try saveText("before sync was on", in: a)
        let syncA = engine(a, folder: folder)
        try a.enqueueFullExport()
        try syncA.sync()
        let b = try makeStore(device: "mac-b")
        try engine(b, folder: folder).sync()
        XCTAssertEqual(try b.items(matching: ItemQuery()).first?.text, "before sync was on")
    }

    func testImportRespectsLocalRetention() throws {
        let folder = try makeDirectory()
        let a = try makeStore(device: "mac-a")
        try saveText("very old", in: a, at: Date(timeIntervalSinceNow: -400 * 86_400))
        try a.enqueueFullExport()
        try engine(a, folder: folder).sync()
        let b = try makeStore(device: "mac-b")
        let syncB = engine(b, folder: folder)
        syncB.retention = .month
        try syncB.sync()
        XCTAssertEqual(try b.totalItemCount(), 0)
    }
}
