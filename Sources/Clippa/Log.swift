import Foundation
import os

/// Clippa's diagnostic log: ~/Library/Logs/Clippa/clippa.log (also in the
/// Console app under com.massimodascola.clippa). It records what Clippa did
/// and what went wrong, never what was copied: no text, no images, no file
/// names, no app names. The diagnostic report includes its last lines.
enum Log {
    static let directory: URL = {
        // A test copy started with CLIPPA_DATA_DIR keeps its log with its data.
        if let override = ProcessInfo.processInfo.environment["CLIPPA_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("Logs", isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Clippa", isDirectory: true)
    }()
    static let file = directory.appendingPathComponent("clippa.log")
    private static let previous = directory.appendingPathComponent("clippa.1.log")
    /// The log is kept under about 2 MB: past 1 MB it moves to clippa.1.log.
    private static let maxSize = 1_000_000

    private static let queue = DispatchQueue(label: "clippa.log", qos: .utility)
    private static let system = Logger(subsystem: "com.massimodascola.clippa", category: "app")
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    static func info(_ message: String) {
        write("INFO", message)
        system.info("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        write("WARN", message)
        system.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String, _ error: Error? = nil) {
        let text = error.map { "\(message): \(describe($0))" } ?? message
        write("ERROR", text)
        system.error("\(text, privacy: .public)")
    }

    /// Runs `body` and logs the error it throws, if any.
    @discardableResult
    static func attempt<T>(_ what: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            self.error(what, error)
            return nil
        }
    }

    /// The error with its domain and code, which say more than the message.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error) [\(nsError.domain) \(nsError.code)]"
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
        queue.async { append(line) }
    }

    /// Writes at once, for the last words before a crash.
    static func writeNow(_ level: String, _ message: String) {
        queue.sync { append("\(stamp.string(from: Date())) \(level) \(message)\n") }
    }

    private static func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxSize {
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: file, to: previous)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? Data(line.utf8).write(to: file)
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }

    /// The last lines of the log, oldest first.
    static func recentLines(_ count: Int) -> [String] {
        queue.sync {}
        let older = (try? String(contentsOf: previous, encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let lines = (older + current).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(count))
    }
}
