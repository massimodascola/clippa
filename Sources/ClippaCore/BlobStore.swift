import CryptoKit
import Foundation

/// Content-addressed file storage: every blob is saved once, under the
/// SHA-256 of its bytes. Two copies of the same image share one file, and a
/// blob name never changes, which keeps sync simple.
public final class BlobStore: @unchecked Sendable {
    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) throws {
        self.directory = directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func url(for hash: String) -> URL {
        directory.appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    /// Saves the data (if new) and returns its hash.
    @discardableResult
    public func write(_ data: Data) throws -> String {
        let hash = Self.hash(data)
        try write(data, hash: hash)
        return hash
    }

    /// Saves data whose hash is already known (used by sync, after checking it).
    public func write(_ data: Data, hash: String) throws {
        let url = url(for: hash)
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func exists(_ hash: String) -> Bool {
        fileManager.fileExists(atPath: url(for: hash).path)
    }

    public func read(_ hash: String) -> Data? {
        try? Data(contentsOf: url(for: hash))
    }

    /// Deletes every blob not in `referenced`. Returns how many were removed.
    @discardableResult
    public func removeAll(except referenced: Set<String>) -> Int {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        var removed = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.count == 64, !referenced.contains(name) else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Total size on disk, for Settings.
    public func totalSize() -> Int {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
