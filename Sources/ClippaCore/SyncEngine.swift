import Foundation

/// Syncs the store through a shared folder (iCloud Drive by default, but any
/// synced folder works). No server and no Apple developer account needed.
///
/// Layout of the folder:
///
///     Clippa/
///       devices/<device id>/device.json         name of the Mac
///       devices/<device id>/changes/<time>-b.json   a batch of changes
///       devices/<device id>/changes/<time>-s.json   a snapshot (replaces older files)
///       devices/<device id>/blobs/<sha256>          images and other data
///
/// Every Mac writes only inside its own folder and only reads the others',
/// so two Macs never write the same file and iCloud never has to resolve a
/// conflict. Files are never changed after they are written. Conflicts
/// between Macs are settled per item: the newest change wins.
public final class SyncEngine: @unchecked Sendable {
    public struct Report: Sendable {
        public var exported = 0
        public var imported = 0
        public var waitingForFiles = false
    }

    public let store: ClippaStore
    public let root: URL
    public var mode: JournalMode
    public var retention: HistoryRetention
    /// Bigger blobs are left out of sync (the item still syncs if it has
    /// other representations, e.g. the text of a huge RTF document).
    public var maxBlobSize = 25 * 1024 * 1024
    /// A Mac writes a fresh snapshot and deletes its older files once it has
    /// this many change files.
    public var compactionThreshold = 200

    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(store: ClippaStore, root: URL, mode: JournalMode, retention: HistoryRetention) {
        self.store = store
        self.root = root
        self.mode = mode
        self.retention = retention
    }

    private var devicesURL: URL { root.appendingPathComponent("devices", isDirectory: true) }
    private func deviceURL(_ id: String) -> URL { devicesURL.appendingPathComponent(id, isDirectory: true) }
    private func changesURL(_ id: String) -> URL { deviceURL(id).appendingPathComponent("changes", isDirectory: true) }
    private func blobsURL(_ id: String) -> URL { deviceURL(id).appendingPathComponent("blobs", isDirectory: true) }

    /// Writes local changes, then reads the other Macs' changes.
    @discardableResult
    public func sync(now: Date = Date()) throws -> Report {
        lock.lock()
        defer { lock.unlock() }
        guard mode != .off else { return Report() }
        try prepareFolders()
        var report = Report()
        report.exported = try exportPending(now: now)
        let (imported, waiting) = try importChanges(now: now)
        report.imported = imported
        report.waitingForFiles = waiting
        try compactIfNeeded(now: now)
        return report
    }

    /// The other Macs that sync through this folder.
    public func otherDevices() -> [(id: String, name: String, lastSeen: Date?)] {
        let ids = (try? fileManager.contentsOfDirectory(atPath: devicesURL.path)) ?? []
        return ids.filter { $0 != store.deviceID && !$0.hasPrefix(".") }.map { id in
            let info = readJSON(deviceURL(id).appendingPathComponent("device.json"), as: DeviceInfo.self)
            return (id, info?.name ?? id, info?.updatedAt)
        }
    }

    // MARK: - Writing

    private struct DeviceInfo: Codable {
        var name: String
        var updatedAt: Date
        var format: Int
    }

    private func prepareFolders() throws {
        let me = store.deviceID
        try fileManager.createDirectory(at: changesURL(me), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobsURL(me), withIntermediateDirectories: true)
    }

    private func exportPending(now: Date) throws -> Int {
        var exported = 0
        while true {
            let pending = try store.pendingOutbox(limit: 500)
            guard let last = pending.last else { break }
            let events = try pending.compactMap { try prepareForExport($0.event) }
            if !events.isEmpty {
                try writeChangeFile(events, suffix: "b", now: now)
                exported += events.count
            }
            try store.removeOutbox(through: last.seq)
        }
        if exported > 0 { try writeDeviceInfo(now: now) }
        return exported
    }

    /// Copies the item's blobs into this Mac's sync folder and drops the
    /// ones too big to sync. Returns nil if nothing of the item is left.
    private func prepareForExport(_ event: SyncEvent) throws -> SyncEvent? {
        guard case .item(var item) = event else { return event }
        item.representations = item.representations.filter { $0.size <= maxBlobSize }
        guard !item.representations.isEmpty || item.kind == .file else { return nil }
        for hash in item.blobHashes {
            let target = blobsURL(store.deviceID).appendingPathComponent(hash)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            guard let data = store.blobs.read(hash) else { continue }
            try coordinatedWrite(data, to: target)
        }
        return .item(item)
    }

    private func writeChangeFile(_ events: [SyncEvent], suffix: String, now: Date) throws {
        let data = try JSONEncoder.sync.encode(events)
        // Sortable name: milliseconds since 1970, then a random tail so two
        // files written in the same millisecond don't collide.
        let millis = String(format: "%015lld", Int64(now.timeIntervalSince1970 * 1000))
        let name = "\(millis)-\(String(UUID().uuidString.prefix(8)))-\(suffix).json"
        try coordinatedWrite(data, to: changesURL(store.deviceID).appendingPathComponent(name))
    }

    private func writeDeviceInfo(now: Date) throws {
        let info = DeviceInfo(name: store.deviceName, updatedAt: now, format: 1)
        try coordinatedWrite(try JSONEncoder.sync.encode(info),
                             to: deviceURL(store.deviceID).appendingPathComponent("device.json"))
    }

    // MARK: - Reading

    private func importChanges(now: Date) throws -> (Int, Bool) {
        var imported = 0
        var waiting = false
        for (deviceID, _, _) in otherDevices() {
            let cursorKey = "sync.cursor.\(deviceID)"
            let cursor = try store.meta(cursorKey) ?? ""
            let names = changeFiles(of: deviceID).filter { $0 > cursor }
            for (position, name) in names.enumerated() {
                let url = changesURL(deviceID).appendingPathComponent(name)
                guard let events = readJSON(url, as: [SyncEvent].self) else {
                    // Not downloaded yet, or deleted by a compaction: try
                    // again next time (a snapshot will cover it).
                    waiting = true
                    break
                }
                let isNewest = position == names.count - 1
                let age = now.timeIntervalSince(fileDate(name) ?? now)
                var ready = true
                var resolved: [SyncEvent] = []
                for event in events {
                    guard case .item(var item) = event else {
                        resolved.append(event)
                        continue
                    }
                    let missing = try fetchBlobs(of: item, from: deviceID)
                    if !missing.isEmpty {
                        // iCloud may deliver the change file before the
                        // images: wait a while, then give up on them.
                        if isNewest || age < 600 {
                            ready = false
                            break
                        }
                        item.representations.removeAll { missing.contains($0.blob) }
                        if item.thumbnail.map(missing.contains) == true { item.thumbnail = nil }
                        if item.linkImage.map(missing.contains) == true { item.linkImage = nil }
                    }
                    resolved.append(.item(item))
                }
                guard ready else {
                    waiting = true
                    break
                }
                for event in resolved where try store.apply(event, mode: mode, retention: retention, now: now) {
                    imported += 1
                }
                try store.setMeta(cursorKey, name)
            }
        }
        return (imported, waiting)
    }

    /// Change file names of a device, oldest first.
    private func changeFiles(of deviceID: String) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: changesURL(deviceID).path)) ?? []
        return names.compactMap { name -> String? in
            // macOS 13 and older show files not downloaded yet as ".name.icloud".
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                try? fileManager.startDownloadingUbiquitousItem(at: changesURL(deviceID).appendingPathComponent(real))
                return nil
            }
            return name.hasSuffix(".json") ? name : nil
        }.sorted()
    }

    private func fileDate(_ name: String) -> Date? {
        guard let millis = Double(name.prefix(15)) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// Copies missing blobs from another Mac's folder. Returns those not available yet.
    private func fetchBlobs(of item: Item, from deviceID: String) throws -> Set<String> {
        var missing = Set<String>()
        for hash in item.blobHashes where !store.blobs.exists(hash) {
            let source = blobsURL(deviceID).appendingPathComponent(hash)
            guard let data = coordinatedRead(source), BlobStore.hash(data) == hash else {
                missing.insert(hash)
                continue
            }
            try store.blobs.write(data, hash: hash)
        }
        return missing
    }

    // MARK: - Compaction

    private func compactIfNeeded(now: Date) throws {
        let mine = changeFiles(of: store.deviceID)
        guard mine.count >= compactionThreshold else { return }
        try compact(now: now)
    }

    /// Replaces this Mac's change files with one snapshot, and deletes the
    /// blobs the snapshot no longer needs.
    public func compact(now: Date = Date()) throws {
        let before = changeFiles(of: store.deviceID)
        let events = try store.snapshotEvents(mode: mode).compactMap { try prepareForExport($0) }
        try writeChangeFile(events, suffix: "s", now: now)
        for name in before {
            try? fileManager.removeItem(at: changesURL(store.deviceID).appendingPathComponent(name))
        }
        var referenced = Set<String>()
        for case .item(let item) in events { referenced.formUnion(item.blobHashes) }
        let blobNames = (try? fileManager.contentsOfDirectory(atPath: blobsURL(store.deviceID).path)) ?? []
        for name in blobNames where !referenced.contains(name) {
            try? fileManager.removeItem(at: blobsURL(store.deviceID).appendingPathComponent(name))
        }
        try writeDeviceInfo(now: now)
    }

    /// Stops syncing this Mac: removes its folder so the others stop
    /// reading it. Data already on the other Macs stays there.
    public func removeThisDevice() throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: deviceURL(store.deviceID).path) {
            try fileManager.removeItem(at: deviceURL(store.deviceID))
        }
    }

    // MARK: - Coordinated file access (cooperates with iCloud Drive)

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private func coordinatedRead(_ url: URL) -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { target in
            result = try? Data(contentsOf: target)
        }
        return result
    }

    private func readJSON<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
        guard let data = coordinatedRead(url) else { return nil }
        return try? JSONDecoder.sync.decode(type, from: data)
    }
}
