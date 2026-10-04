import Foundation

/// One pasteboard type read at copy time, before it is saved.
public struct CapturedRepresentation: Sendable {
    public var index: Int
    public var type: String
    public var data: Data

    public init(index: Int, type: String, data: Data) {
        self.index = index
        self.type = type
        self.data = data
    }
}

/// Everything the clipboard monitor read from one copy.
public struct CapturedContent: Sendable {
    public var kind: ItemKind
    /// Plain text for preview and search.
    public var text: String
    /// What makes two copies "the same" (the text, the image bytes, the file
    /// paths). Copying the same thing again moves the old card to the front
    /// instead of adding a duplicate.
    public var identity: String
    public var representations: [CapturedRepresentation]
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var thumbnail: Data?
    public var imageWidth: Int?
    public var imageHeight: Int?

    public init(kind: ItemKind, text: String, identity: String, representations: [CapturedRepresentation],
                sourceBundleID: String? = nil, sourceAppName: String? = nil, thumbnail: Data? = nil,
                imageWidth: Int? = nil, imageHeight: Int? = nil) {
        self.kind = kind
        self.text = text
        self.identity = identity
        self.representations = representations
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.thumbnail = thumbnail
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

/// What the store writes to the sync outbox.
public enum JournalMode: String, CaseIterable, Sendable {
    /// Sync is off: nothing is recorded.
    case off
    /// Only pinboards and pinned items leave this Mac.
    case pinboardsOnly
    /// Clipboard History and pinboards.
    case everything
}

/// The clipboard database: items, pinboards and their files.
public final class ClippaStore: @unchecked Sendable {
    public let directory: URL
    public let db: SQLiteDatabase
    public let blobs: BlobStore
    public let deviceID: String
    public let deviceName: String
    /// Set by the sync engine. Every local change is recorded in the outbox
    /// while this is not `.off`.
    public var journalMode: JournalMode = .off

    /// Longest text kept for preview and search. The full text stays in
    /// its representation and is what gets pasted.
    public static let maxIndexedText = 100_000

    public init(directory: URL = ClippaPaths.dataDirectory, deviceID: String, deviceName: String,
                readOnly: Bool = false) throws {
        self.directory = directory
        self.deviceID = deviceID
        self.deviceName = deviceName
        if !readOnly {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        db = try SQLiteDatabase(path: ClippaPaths.databaseURL(in: directory).path, readOnly: readOnly)
        blobs = try BlobStore(directory: ClippaPaths.blobsURL(in: directory))
        if !readOnly {
            try migrate()
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        try db.execute("PRAGMA journal_mode = WAL")
        let version = try db.scalarInt("PRAGMA user_version")
        if version < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS items (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    copied_at REAL NOT NULL,
                    title TEXT,
                    text TEXT NOT NULL DEFAULT '',
                    ocr_text TEXT,
                    link_title TEXT,
                    link_image TEXT,
                    thumbnail TEXT,
                    image_width INTEGER,
                    image_height INTEGER,
                    byte_size INTEGER NOT NULL DEFAULT 0,
                    content_hash TEXT NOT NULL,
                    source_bundle_id TEXT,
                    source_app_name TEXT,
                    device_id TEXT NOT NULL,
                    device_name TEXT NOT NULL,
                    pinboard_id TEXT,
                    pin_order REAL NOT NULL DEFAULT 0,
                    in_history INTEGER NOT NULL DEFAULT 1,
                    keep_mode TEXT NOT NULL DEFAULT 'auto',
                    keep_until REAL,
                    reps TEXT NOT NULL DEFAULT '[]',
                    modified_at REAL NOT NULL,
                    modified_by TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS items_copied ON items(copied_at DESC);
                CREATE INDEX IF NOT EXISTS items_hash ON items(content_hash);
                CREATE INDEX IF NOT EXISTS items_pinboard ON items(pinboard_id, pin_order);
                CREATE TABLE IF NOT EXISTS pinboards (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    color INTEGER NOT NULL,
                    sort_order REAL NOT NULL,
                    modified_at REAL NOT NULL,
                    modified_by TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS tombstones (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    deleted_at REAL NOT NULL,
                    deleted_by TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS paste_log (
                    item_id TEXT NOT NULL,
                    target_bundle_id TEXT,
                    at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS paste_log_target ON paste_log(target_bundle_id);
                CREATE TABLE IF NOT EXISTS outbox (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    event TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value TEXT
                );
                """)
                // Trigram search finds any part of a word ("bot" finds
                // "Dalebotics"). remove_diacritics needs SQLite 3.45
                // (macOS 15); older systems get plain trigrams.
                let fts = "CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(title, text, ocr_text, link_title, source_app_name, content='items', content_rowid='seq', tokenize="
                do {
                    try db.execute(fts + "'trigram remove_diacritics 1')")
                } catch {
                    try db.execute(fts + "'trigram')")
                }
                let columns = "title, text, ocr_text, link_title, source_app_name"
                let newValues = "new.title, new.text, new.ocr_text, new.link_title, new.source_app_name"
                let oldValues = "old.title, old.text, old.ocr_text, old.link_title, old.source_app_name"
                try db.execute("""
                CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
                    INSERT INTO items_fts(rowid, \(columns)) VALUES (new.seq, \(newValues));
                END;
                CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
                    INSERT INTO items_fts(items_fts, rowid, \(columns)) VALUES ('delete', old.seq, \(oldValues));
                END;
                CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF \(columns) ON items BEGIN
                    INSERT INTO items_fts(items_fts, rowid, \(columns)) VALUES ('delete', old.seq, \(oldValues));
                    INSERT INTO items_fts(rowid, \(columns)) VALUES (new.seq, \(newValues));
                END;
                """)
                try db.execute("PRAGMA user_version = 1")
            }
        }
    }

    // MARK: - Reading

    private static let itemColumns = """
    id, kind, created_at, copied_at, title, text, ocr_text, link_title, link_image, thumbnail, \
    image_width, image_height, byte_size, content_hash, source_bundle_id, source_app_name, \
    device_id, device_name, pinboard_id, pin_order, in_history, keep_mode, keep_until, reps, \
    modified_at, modified_by
    """

    private static func item(from row: SQLiteRow) -> Item {
        let reps = (try? JSONDecoder().decode([Representation].self, from: Data(row.string(23).utf8))) ?? []
        return Item(
            id: row.string(0),
            kind: ItemKind(rawValue: row.string(1)) ?? .text,
            createdAt: row.date(2),
            copiedAt: row.date(3),
            title: row.optionalString(4),
            text: row.string(5),
            ocrText: row.optionalString(6),
            linkTitle: row.optionalString(7),
            linkImage: row.optionalString(8),
            thumbnail: row.optionalString(9),
            imageWidth: row.optionalInt(10),
            imageHeight: row.optionalInt(11),
            byteSize: row.int(12),
            contentHash: row.string(13),
            sourceBundleID: row.optionalString(14),
            sourceAppName: row.optionalString(15),
            deviceID: row.string(16),
            deviceName: row.string(17),
            pinboardID: row.optionalString(18),
            pinOrder: row.double(19),
            inHistory: row.int(20) != 0,
            keep: KeepRule.stored(mode: row.string(21), date: row.optionalDate(22)),
            representations: reps,
            modifiedAt: row.date(24),
            modifiedBy: row.string(25)
        )
    }

    public func item(id: String) throws -> Item? {
        try db.query("SELECT \(Self.itemColumns) FROM items WHERE id = ?", [id], map: Self.item).first
    }

    public func items(ids: [String]) throws -> [Item] {
        guard !ids.isEmpty else { return [] }
        let found = try db.query("SELECT \(Self.itemColumns) FROM items WHERE id IN (\(placeholders(ids.count)))",
                                 ids, map: Self.item)
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    public func items(matching query: ItemQuery) throws -> [Item] {
        let (whereClause, params) = filter(for: query)
        let order: String
        if case .pinboard = query.list, !query.isFiltering || !query.searchAllLists {
            order = "pin_order ASC, copied_at DESC"
        } else {
            order = "copied_at DESC"
        }
        return try db.query("SELECT \(Self.itemColumns) FROM items WHERE \(whereClause) ORDER BY \(order) LIMIT ? OFFSET ?",
                            params + [query.limit, query.offset], map: Self.item)
    }

    public func count(matching query: ItemQuery) throws -> Int {
        let (whereClause, params) = filter(for: query)
        return try db.scalarInt("SELECT COUNT(*) FROM items WHERE \(whereClause)", params)
    }

    private func filter(for query: ItemQuery) -> (String, [Any?]) {
        var conditions: [String] = []
        var params: [Any?] = []
        if !query.isFiltering || !query.searchAllLists {
            switch query.list {
            case .history:
                conditions.append("in_history = 1")
            case .pinboard(let id):
                conditions.append("pinboard_id = ?")
                params.append(id)
            }
        }
        let terms = query.terms
        // Trigrams need three characters; shorter terms use LIKE.
        let long = terms.filter { $0.count >= 3 }
        let short = terms.filter { $0.count < 3 }
        if !long.isEmpty {
            conditions.append("seq IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)")
            params.append(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: " AND "))
        }
        for term in short {
            conditions.append("""
            (COALESCE(title, '') || ' ' || text || ' ' || COALESCE(ocr_text, '') || ' ' || \
            COALESCE(link_title, '') || ' ' || COALESCE(source_app_name, '')) LIKE ? ESCAPE '\\'
            """)
            let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            params.append("%\(escaped)%")
        }
        if !query.kinds.isEmpty {
            conditions.append("kind IN (\(placeholders(query.kinds.count)))")
            params += query.kinds.map(\.rawValue).sorted()
        }
        if !query.apps.isEmpty {
            conditions.append("source_bundle_id IN (\(placeholders(query.apps.count)))")
            params += query.apps.sorted()
        }
        if !query.devices.isEmpty {
            conditions.append("device_id IN (\(placeholders(query.devices.count)))")
            params += query.devices.sorted()
        }
        if let date = query.date {
            let range = date.range()
            conditions.append("copied_at BETWEEN ? AND ?")
            params += [range.lowerBound, range.upperBound]
        }
        if let since = query.since {
            conditions.append("copied_at >= ?")
            params.append(since)
        }
        return (conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), params)
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    public func pinboards() throws -> [Pinboard] {
        try db.query("SELECT id, name, color, sort_order, modified_at, modified_by FROM pinboards ORDER BY sort_order, name") {
            Pinboard(id: $0.string(0), name: $0.string(1), color: PinboardColor(rawValue: $0.int(2)) ?? .blue,
                     sortOrder: $0.double(3), modifiedAt: $0.date(4), modifiedBy: $0.string(5))
        }
    }

    public func pinboardItemCounts() throws -> [String: Int] {
        let rows = try db.query("SELECT pinboard_id, COUNT(*) FROM items WHERE pinboard_id IS NOT NULL GROUP BY pinboard_id") {
            ($0.string(0), $0.int(1))
        }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    public func sourceApps() throws -> [SourceApp] {
        try db.query("""
        SELECT source_bundle_id, MAX(source_app_name), COUNT(*) FROM items
        WHERE source_bundle_id IS NOT NULL GROUP BY source_bundle_id ORDER BY COUNT(*) DESC
        """) {
            SourceApp(bundleID: $0.string(0), name: $0.optionalString(1) ?? $0.string(0), count: $0.int(2))
        }
    }

    public func devices() throws -> [SourceDevice] {
        try db.query("SELECT device_id, MAX(device_name) FROM items GROUP BY device_id ORDER BY MAX(device_name)") {
            SourceDevice(id: $0.string(0), name: $0.string(1))
        }
    }

    public func totalItemCount() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM items")
    }

    // MARK: - Writing items

    /// Saves a new copy. Copying something already saved moves that item to
    /// the front of the history instead of adding a duplicate.
    @discardableResult
    public func save(_ capture: CapturedContent, at now: Date = Date()) throws -> Item {
        var representations: [Representation] = []
        for rep in capture.representations {
            let hash = try blobs.write(rep.data)
            representations.append(Representation(index: rep.index, type: rep.type, blob: hash, size: rep.data.count))
        }
        let thumbnail = try capture.thumbnail.map { try blobs.write($0) }
        let contentHash = BlobStore.hash(Data((capture.kind.rawValue + "\n" + capture.identity).utf8))
        let byteSize = capture.representations.reduce(0) { $0 + $1.data.count }

        return try db.transaction {
            if var existing = try db.query("SELECT \(Self.itemColumns) FROM items WHERE content_hash = ? ORDER BY copied_at DESC LIMIT 1",
                                           [contentHash], map: Self.item).first {
                let wasPinned = existing.isPinned
                existing.copiedAt = now
                existing.inHistory = true
                existing.sourceBundleID = capture.sourceBundleID ?? existing.sourceBundleID
                existing.sourceAppName = capture.sourceAppName ?? existing.sourceAppName
                existing.representations = representations
                existing.byteSize = byteSize
                existing.thumbnail = thumbnail ?? existing.thumbnail
                existing.deviceID = deviceID
                existing.deviceName = deviceName
                existing.modifiedAt = now
                existing.modifiedBy = deviceID
                try write(existing)
                journal(.item(existing), wasPinned: wasPinned)
                return existing
            }
            // Same content gets the same id on every Mac, so sync merges
            // the two copies instead of showing both.
            var id = String(contentHash.prefix(32))
            if try db.scalarInt("SELECT COUNT(*) FROM items WHERE id = ?", [id]) > 0 {
                id = UUID().uuidString
            }
            try db.run("DELETE FROM tombstones WHERE id = ?", [id])
            let item = Item(id: id, kind: capture.kind, createdAt: now, copiedAt: now,
                            text: String(capture.text.prefix(Self.maxIndexedText)),
                            thumbnail: thumbnail, imageWidth: capture.imageWidth, imageHeight: capture.imageHeight,
                            byteSize: byteSize, contentHash: contentHash,
                            sourceBundleID: capture.sourceBundleID, sourceAppName: capture.sourceAppName,
                            deviceID: deviceID, deviceName: deviceName,
                            representations: representations, modifiedAt: now, modifiedBy: deviceID)
            try write(item)
            journal(.item(item), wasPinned: false)
            return item
        }
    }

    /// Creates a text item typed by the user (Command-N) or sent by an AI tool.
    @discardableResult
    public func createTextItem(_ text: String, title: String? = nil, pinboardID: String? = nil,
                               at now: Date = Date()) throws -> Item {
        let data = Data(text.utf8)
        let hash = try blobs.write(data)
        let kind = Classifier.kind(forText: text)
        let contentHash = BlobStore.hash(Data((kind.rawValue + "\n" + text).utf8))
        return try db.transaction {
            let order = try pinboardID.map { try db.query("SELECT MIN(pin_order) FROM items WHERE pinboard_id = ?", [$0]) { $0.isNull(0) ? 0 : $0.double(0) }.first ?? 0 } ?? 0
            let item = Item(kind: kind, createdAt: now, copiedAt: now, title: title,
                            text: String(text.prefix(Self.maxIndexedText)), byteSize: data.count,
                            contentHash: contentHash, sourceBundleID: ClippaPaths.bundleID, sourceAppName: "Clippa",
                            deviceID: deviceID, deviceName: deviceName, pinboardID: pinboardID,
                            pinOrder: order - 1, inHistory: pinboardID == nil,
                            representations: [Representation(index: 0, type: UTType.plainText, blob: hash, size: data.count)],
                            modifiedAt: now, modifiedBy: deviceID)
            try write(item)
            journal(.item(item), wasPinned: false)
            return item
        }
    }

    /// Saves every field of an item, stamping it as changed by this Mac now.
    public func update(_ item: Item, at now: Date = Date()) throws {
        try db.transaction {
            let wasPinned = try self.item(id: item.id)?.isPinned ?? false
            var changed = item
            changed.modifiedAt = now
            changed.modifiedBy = deviceID
            if changed.text.count > Self.maxIndexedText {
                changed.text = String(changed.text.prefix(Self.maxIndexedText))
            }
            try write(changed)
            journal(.item(changed), wasPinned: wasPinned)
        }
    }

    /// Applies a change to several items in one transaction.
    public func modify(ids: [String], at now: Date = Date(), _ change: (inout Item) throws -> Void) throws {
        try db.transaction {
            for var item in try items(ids: ids) {
                let wasPinned = item.isPinned
                try change(&item)
                item.modifiedAt = now
                item.modifiedBy = deviceID
                try write(item)
                journal(.item(item), wasPinned: wasPinned)
            }
        }
    }

    public func setTitle(_ title: String?, for id: String) throws {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try modify(ids: [id]) { $0.title = (cleaned?.isEmpty ?? true) ? nil : cleaned }
    }

    public func setKeep(_ rule: KeepRule, for ids: [String]) throws {
        try modify(ids: ids) { $0.keep = rule }
    }

    /// Marks an item as just copied: it moves to the front of the history.
    public func markCopied(_ id: String, at now: Date = Date()) throws {
        try modify(ids: [id], at: now) {
            $0.copiedAt = now
            $0.inHistory = true
        }
    }

    /// Puts items in a pinboard (at its front), or takes them out with nil.
    /// An item that is no longer in the history disappears when unpinned.
    public func pin(_ ids: [String], to pinboardID: String?, at now: Date = Date()) throws {
        try db.transaction {
            guard let pinboardID else {
                let leaving = try items(ids: ids)
                let orphans = leaving.filter { !$0.inHistory }.map(\.id)
                try modify(ids: leaving.filter(\.inHistory).map(\.id), at: now) { $0.pinboardID = nil }
                try delete(ids: orphans, at: now)
                return
            }
            var order = try db.query("SELECT MIN(pin_order) FROM items WHERE pinboard_id = ?", [pinboardID]) {
                $0.isNull(0) ? 0 : $0.double(0)
            }.first ?? 0
            for id in ids.reversed() {
                order -= 1
                let newOrder = order
                try modify(ids: [id], at: now) {
                    $0.pinboardID = pinboardID
                    $0.pinOrder = newOrder
                }
            }
        }
    }

    /// Moves an item inside its pinboard so it sits at `index`.
    public func move(_ id: String, toIndex index: Int, in pinboardID: String, at now: Date = Date()) throws {
        try db.transaction {
            var ids = try db.query("SELECT id FROM items WHERE pinboard_id = ? ORDER BY pin_order, copied_at DESC",
                                   [pinboardID]) { $0.string(0) }
            guard let from = ids.firstIndex(of: id) else { return }
            ids.remove(at: from)
            ids.insert(id, at: max(0, min(index, ids.count)))
            for (position, itemID) in ids.enumerated() {
                let current = try db.query("SELECT pin_order FROM items WHERE id = ?", [itemID]) { $0.double(0) }.first
                if current != Double(position) {
                    try modify(ids: [itemID], at: now) { $0.pinOrder = Double(position) }
                }
            }
        }
    }

    /// Deletes items everywhere (history and pinboards) and returns them, so
    /// the deletion can be undone with `restore`.
    @discardableResult
    public func delete(ids: [String], at now: Date = Date()) throws -> [Item] {
        guard !ids.isEmpty else { return [] }
        return try db.transaction {
            let removed = try items(ids: ids)
            for item in removed {
                try db.run("DELETE FROM items WHERE id = ?", [item.id])
                let tombstone = Tombstone(id: item.id, kind: .item, deletedAt: now, deletedBy: deviceID)
                try writeTombstone(tombstone)
                journal(.tombstone(tombstone), wasPinned: item.isPinned)
            }
            return removed
        }
    }

    /// Puts back items removed by `delete` (Undo).
    public func restore(_ items: [Item], at now: Date = Date()) throws {
        try db.transaction {
            for var item in items {
                try db.run("DELETE FROM tombstones WHERE id = ?", [item.id])
                item.modifiedAt = now
                item.modifiedBy = deviceID
                try write(item)
                journal(.item(item), wasPinned: item.isPinned)
            }
        }
    }

    // MARK: - Retention

    /// Applies Keep History and the per-item rules. Un-pinned items older
    /// than the limit are deleted; pinned ones just leave the history.
    /// Expiry happens on each Mac by itself, so it is not synced.
    @discardableResult
    public func purgeExpired(retention: HistoryRetention, now: Date = Date()) throws -> Int {
        try db.transaction {
            var deleted = try db.run("DELETE FROM items WHERE keep_mode = 'until' AND keep_until <= ?", [now])
            if let cutoff = retention.cutoff(now: now) {
                deleted += try db.run("""
                DELETE FROM items WHERE keep_mode = 'auto' AND pinboard_id IS NULL AND copied_at < ?
                """, [cutoff])
                try db.run("""
                UPDATE items SET in_history = 0
                WHERE keep_mode = 'auto' AND pinboard_id IS NOT NULL AND in_history = 1 AND copied_at < ?
                """, [cutoff])
            }
            // Tombstones only need to live long enough to reach other Macs.
            try db.run("DELETE FROM tombstones WHERE deleted_at < ?", [now.addingTimeInterval(-180 * 86_400)])
            try db.run("DELETE FROM paste_log WHERE at < ?", [now.addingTimeInterval(-180 * 86_400)])
            return deleted
        }
    }

    /// How many items a stricter Keep History would delete (for the warning).
    public func countExpiring(under retention: HistoryRetention, now: Date = Date()) throws -> Int {
        guard let cutoff = retention.cutoff(now: now) else { return 0 }
        return try db.scalarInt("""
        SELECT COUNT(*) FROM items WHERE keep_mode = 'auto' AND pinboard_id IS NULL AND copied_at < ?
        """, [cutoff])
    }

    /// Settings → Erase History. Pinned items stay in their pinboards, items
    /// marked "Keep forever" stay where they are.
    @discardableResult
    public func eraseHistory(at now: Date = Date()) throws -> Int {
        let ids = try db.query("""
        SELECT id FROM items WHERE in_history = 1 AND pinboard_id IS NULL AND keep_mode != 'forever'
        """) { $0.string(0) }
        try delete(ids: ids, at: now)
        let pinned = try db.query("""
        SELECT id FROM items WHERE in_history = 1 AND pinboard_id IS NOT NULL AND keep_mode != 'forever'
        """) { $0.string(0) }
        try modify(ids: pinned, at: now) { $0.inHistory = false }
        return ids.count
    }

    // MARK: - Pinboards

    @discardableResult
    public func createPinboard(name: String, color: PinboardColor, at now: Date = Date()) throws -> Pinboard {
        let last = try db.query("SELECT MAX(sort_order) FROM pinboards") { $0.isNull(0) ? 0 : $0.double(0) }.first ?? 0
        let pinboard = Pinboard(name: name, color: color, sortOrder: last + 1, modifiedAt: now, modifiedBy: deviceID)
        try savePinboard(pinboard, at: now)
        return pinboard
    }

    public func savePinboard(_ pinboard: Pinboard, at now: Date = Date()) throws {
        var changed = pinboard
        changed.modifiedAt = now
        changed.modifiedBy = deviceID
        try db.transaction {
            try writePinboard(changed)
            journal(.pinboard(changed), wasPinned: true)
        }
    }

    /// Deletes a pinboard and every item inside it, like Paste.
    public func deletePinboard(id: String, at now: Date = Date()) throws {
        try db.transaction {
            let ids = try db.query("SELECT id FROM items WHERE pinboard_id = ?", [id]) { $0.string(0) }
            try delete(ids: ids, at: now)
            try db.run("DELETE FROM pinboards WHERE id = ?", [id])
            let tombstone = Tombstone(id: id, kind: .pinboard, deletedAt: now, deletedBy: deviceID)
            try writeTombstone(tombstone)
            journal(.tombstone(tombstone), wasPinned: true)
        }
    }

    /// Saves a new order for the pinboards.
    public func reorderPinboards(_ ids: [String], at now: Date = Date()) throws {
        try db.transaction {
            let byID = Dictionary(try pinboards().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (position, id) in ids.enumerated() {
                guard var pinboard = byID[id], pinboard.sortOrder != Double(position) else { continue }
                pinboard.sortOrder = Double(position)
                try savePinboard(pinboard, at: now)
            }
        }
    }

    // MARK: - Paste history (for suggestions)

    public func recordPaste(itemID: String, into targetBundleID: String?, at now: Date = Date()) throws {
        try db.run("INSERT INTO paste_log (item_id, target_bundle_id, at) VALUES (?, ?, ?)",
                   [itemID, targetBundleID, now])
    }

    /// How many times each item was pasted into an app.
    public func pasteCounts(into targetBundleID: String) throws -> [String: Int] {
        let rows = try db.query("SELECT item_id, COUNT(*) FROM paste_log WHERE target_bundle_id = ? GROUP BY item_id",
                                [targetBundleID]) { ($0.string(0), $0.int(1)) }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    /// How many times each kind of item was pasted into an app.
    public func pastedKinds(into targetBundleID: String) throws -> [ItemKind: Int] {
        let rows = try db.query("""
        SELECT items.kind, COUNT(*) FROM paste_log JOIN items ON items.id = paste_log.item_id
        WHERE paste_log.target_bundle_id = ? GROUP BY items.kind
        """, [targetBundleID]) { (ItemKind(rawValue: $0.string(0)) ?? .text, $0.int(1)) }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    // MARK: - Housekeeping

    /// Removes files no item points to any more.
    @discardableResult
    public func collectGarbage() throws -> Int {
        var referenced = Set<String>()
        let rows = try db.query("SELECT reps, thumbnail, link_image FROM items") {
            ($0.string(0), $0.optionalString(1), $0.optionalString(2))
        }
        for (reps, thumbnail, linkImage) in rows {
            let decoded = (try? JSONDecoder().decode([Representation].self, from: Data(reps.utf8))) ?? []
            referenced.formUnion(decoded.map(\.blob))
            if let thumbnail { referenced.insert(thumbnail) }
            if let linkImage { referenced.insert(linkImage) }
        }
        return blobs.removeAll(except: referenced)
    }

    public func meta(_ key: String) throws -> String? {
        try db.scalarString("SELECT value FROM meta WHERE key = ?", [key])
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [key, value])
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", [key])
        }
    }

    // MARK: - Low level

    func write(_ item: Item) throws {
        let reps = String(decoding: try JSONEncoder().encode(item.representations), as: UTF8.self)
        try db.run("""
        INSERT INTO items (\(Self.itemColumns)) VALUES (\(placeholders(26)))
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind, created_at = excluded.created_at, copied_at = excluded.copied_at,
            title = excluded.title, text = excluded.text, ocr_text = excluded.ocr_text,
            link_title = excluded.link_title, link_image = excluded.link_image, thumbnail = excluded.thumbnail,
            image_width = excluded.image_width, image_height = excluded.image_height,
            byte_size = excluded.byte_size, content_hash = excluded.content_hash,
            source_bundle_id = excluded.source_bundle_id, source_app_name = excluded.source_app_name,
            device_id = excluded.device_id, device_name = excluded.device_name,
            pinboard_id = excluded.pinboard_id, pin_order = excluded.pin_order,
            in_history = excluded.in_history, keep_mode = excluded.keep_mode, keep_until = excluded.keep_until,
            reps = excluded.reps, modified_at = excluded.modified_at, modified_by = excluded.modified_by
        """, [
            item.id, item.kind.rawValue, item.createdAt, item.copiedAt, item.title, item.text, item.ocrText,
            item.linkTitle, item.linkImage, item.thumbnail, item.imageWidth, item.imageHeight, item.byteSize,
            item.contentHash, item.sourceBundleID, item.sourceAppName, item.deviceID, item.deviceName,
            item.pinboardID, item.pinOrder, item.inHistory, item.keep.storedMode, item.keep.storedDate, reps,
            item.modifiedAt, item.modifiedBy,
        ])
    }

    func writePinboard(_ pinboard: Pinboard) throws {
        try db.run("""
        INSERT INTO pinboards (id, name, color, sort_order, modified_at, modified_by) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color,
            sort_order = excluded.sort_order, modified_at = excluded.modified_at, modified_by = excluded.modified_by
        """, [pinboard.id, pinboard.name, pinboard.color.rawValue, pinboard.sortOrder, pinboard.modifiedAt, pinboard.modifiedBy])
    }

    func writeTombstone(_ tombstone: Tombstone) throws {
        try db.run("""
        INSERT INTO tombstones (id, kind, deleted_at, deleted_by) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at), deleted_by = excluded.deleted_by
        """, [tombstone.id, tombstone.kind.rawValue, tombstone.deletedAt, tombstone.deletedBy])
    }

    func tombstone(id: String) throws -> Tombstone? {
        try db.query("SELECT id, kind, deleted_at, deleted_by FROM tombstones WHERE id = ?", [id]) {
            Tombstone(id: $0.string(0), kind: Tombstone.Kind(rawValue: $0.string(1)) ?? .item,
                      deletedAt: $0.date(2), deletedBy: $0.string(3))
        }.first
    }

    /// Records a local change for sync, if sync wants it.
    func journal(_ event: SyncEvent, wasPinned: Bool) {
        switch journalMode {
        case .off:
            return
        case .pinboardsOnly:
            switch event {
            case .item(let item) where !item.isPinned && !wasPinned:
                return
            case .tombstone(let tombstone) where tombstone.kind == .item && !wasPinned:
                return
            default:
                break
            }
        case .everything:
            break
        }
        guard let data = try? JSONEncoder.sync.encode(event) else { return }
        _ = try? db.run("INSERT INTO outbox (event) VALUES (?)", [String(decoding: data, as: UTF8.self)])
    }
}
