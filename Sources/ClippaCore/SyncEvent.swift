import Foundation

/// One change that travels between Macs.
public enum SyncEvent: Codable, Sendable {
    case item(Item)
    case pinboard(Pinboard)
    case tombstone(Tombstone)

    private enum CodingKeys: String, CodingKey { case type, item, pinboard, tombstone }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "item": self = .item(try container.decode(Item.self, forKey: .item))
        case "pinboard": self = .pinboard(try container.decode(Pinboard.self, forKey: .pinboard))
        case "tombstone": self = .tombstone(try container.decode(Tombstone.self, forKey: .tombstone))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "Unknown event type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .item(let item):
            try container.encode("item", forKey: .type)
            try container.encode(item, forKey: .item)
        case .pinboard(let pinboard):
            try container.encode("pinboard", forKey: .type)
            try container.encode(pinboard, forKey: .pinboard)
        case .tombstone(let tombstone):
            try container.encode("tombstone", forKey: .type)
            try container.encode(tombstone, forKey: .tombstone)
        }
    }
}

extension JSONEncoder {
    static var sync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var sync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// Last writer wins: the newer change, with the device id breaking ties so
/// every Mac picks the same winner.
func isNewer(_ date: Date, by device: String, than otherDate: Date, by otherDevice: String) -> Bool {
    if date != otherDate { return date > otherDate }
    return device > otherDevice
}

// MARK: - Store support for sync

public extension ClippaStore {
    /// Local changes waiting to be written to the sync folder.
    func pendingOutbox(limit: Int = 500) throws -> [(seq: Int, event: SyncEvent)] {
        try db.query("SELECT seq, event FROM outbox ORDER BY seq LIMIT ?", [limit]) { row in
            (row.int(0), try JSONDecoder.sync.decode(SyncEvent.self, from: Data(row.string(1).utf8)))
        }
    }

    func removeOutbox(through seq: Int) throws {
        try db.run("DELETE FROM outbox WHERE seq <= ?", [seq])
    }

    func clearOutbox() throws {
        try db.run("DELETE FROM outbox")
    }

    /// Queues every pinboard and every item the mode allows, for the first
    /// sync of this Mac.
    func enqueueFullExport() throws {
        try db.transaction {
            for pinboard in try pinboards() {
                journal(.pinboard(pinboard), wasPinned: true)
            }
            let ids = try db.query("SELECT id FROM items ORDER BY copied_at") { $0.string(0) }
            for chunk in stride(from: 0, to: ids.count, by: 500) {
                for item in try items(ids: Array(ids[chunk..<min(chunk + 500, ids.count)])) {
                    journal(.item(item), wasPinned: item.isPinned)
                }
            }
        }
    }

    /// The current state this Mac is responsible for: what it changed last.
    /// Written as a snapshot so old change files can be deleted.
    func snapshotEvents(mode: JournalMode) throws -> [SyncEvent] {
        var events: [SyncEvent] = try pinboards().filter { $0.modifiedBy == deviceID }.map { .pinboard($0) }
        let ids = try db.query("SELECT id FROM items WHERE modified_by = ?", [deviceID]) { $0.string(0) }
        for chunk in stride(from: 0, to: ids.count, by: 500) {
            let items = try items(ids: Array(ids[chunk..<min(chunk + 500, ids.count)]))
            events += items.filter { mode == .everything || $0.isPinned }.map { .item($0) }
        }
        events += try db.query("SELECT id, kind, deleted_at, deleted_by FROM tombstones WHERE deleted_by = ?", [deviceID]) {
            .tombstone(Tombstone(id: $0.string(0), kind: Tombstone.Kind(rawValue: $0.string(1)) ?? .item,
                                 deletedAt: $0.date(2), deletedBy: $0.string(3)))
        }
        return events
    }

    /// Applies a change made on another Mac. Returns true if anything changed.
    /// Nothing is journaled, so changes don't bounce back.
    @discardableResult
    func apply(_ event: SyncEvent, mode: JournalMode, retention: HistoryRetention, now: Date = Date()) throws -> Bool {
        try db.transaction {
            switch event {
            case .item(let remote):
                if let tombstone = try tombstone(id: remote.id),
                   !isNewer(remote.modifiedAt, by: remote.modifiedBy, than: tombstone.deletedAt, by: tombstone.deletedBy) {
                    return false
                }
                if let local = try item(id: remote.id) {
                    guard isNewer(remote.modifiedAt, by: remote.modifiedBy, than: local.modifiedAt, by: local.modifiedBy) else {
                        return false
                    }
                    if mode == .pinboardsOnly && !remote.isPinned && !local.isPinned { return false }
                } else {
                    if mode == .pinboardsOnly && !remote.isPinned { return false }
                    // Respect this Mac's own Keep History.
                    if remote.keep == .automatic, !remote.isPinned,
                       let cutoff = retention.cutoff(now: now), remote.copiedAt < cutoff {
                        return false
                    }
                    if case .until(let date) = remote.keep, date <= now { return false }
                }
                try db.run("DELETE FROM tombstones WHERE id = ?", [remote.id])
                try write(remote)
                return true
            case .pinboard(let remote):
                if let tombstone = try tombstone(id: remote.id),
                   !isNewer(remote.modifiedAt, by: remote.modifiedBy, than: tombstone.deletedAt, by: tombstone.deletedBy) {
                    return false
                }
                if let local = try pinboards().first(where: { $0.id == remote.id }),
                   !isNewer(remote.modifiedAt, by: remote.modifiedBy, than: local.modifiedAt, by: local.modifiedBy) {
                    return false
                }
                try writePinboard(remote)
                return true
            case .tombstone(let remote):
                try writeTombstone(remote)
                switch remote.kind {
                case .item:
                    guard let local = try item(id: remote.id),
                          !isNewer(local.modifiedAt, by: local.modifiedBy, than: remote.deletedAt, by: remote.deletedBy) else {
                        return false
                    }
                    try db.run("DELETE FROM items WHERE id = ?", [remote.id])
                    return true
                case .pinboard:
                    guard try pinboardExists(remote.id) else { return false }
                    try db.run("DELETE FROM pinboards WHERE id = ?", [remote.id])
                    // Items of a deleted pinboard arrive as their own tombstones;
                    // any left over go back to the history rather than vanish.
                    try db.run("UPDATE items SET pinboard_id = NULL, in_history = 1 WHERE pinboard_id = ?", [remote.id])
                    return true
                }
            }
        }
    }

    private func pinboardExists(_ id: String) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM pinboards WHERE id = ?", [id]) > 0
    }
}
