import Foundation

/// Settings → Keep History. Same choices as Paste; one month is the default.
public enum HistoryRetention: String, CaseIterable, Codable, Sendable {
    case day, week, month, year, forever

    public static let `default` = HistoryRetention.month

    /// How long an un-pinned item stays, or nil for forever.
    public var interval: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .year: return 365 * 86_400
        case .forever: return nil
        }
    }

    /// Oldest copy date still kept, or nil for forever.
    public func cutoff(now: Date) -> Date? {
        interval.map { now.addingTimeInterval(-$0) }
    }
}

/// The per-item choices offered by the "Keep" menu of a card.
public enum KeepChoice: String, CaseIterable, Sendable {
    case automatic, hour, day, week, month, year, forever

    public func rule(now: Date = Date()) -> KeepRule {
        switch self {
        case .automatic: return .automatic
        case .forever: return .forever
        case .hour: return .until(now.addingTimeInterval(3_600))
        case .day: return .until(now.addingTimeInterval(86_400))
        case .week: return .until(now.addingTimeInterval(7 * 86_400))
        case .month: return .until(now.addingTimeInterval(30 * 86_400))
        case .year: return .until(now.addingTimeInterval(365 * 86_400))
        }
    }
}

public extension Item {
    /// When this item will be deleted automatically, or nil if never.
    func expiryDate(retention: HistoryRetention) -> Date? {
        switch keep {
        case .forever:
            return nil
        case .until(let date):
            return date
        case .automatic:
            guard !isPinned, let interval = retention.interval else { return nil }
            return copiedAt.addingTimeInterval(interval)
        }
    }
}
