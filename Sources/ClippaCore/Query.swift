import Foundation

/// What the shelf (or an MCP client) is asking for.
public struct ItemQuery: Hashable, Sendable {
    public enum List: Hashable, Sendable {
        /// Clipboard History: everything copied, newest first.
        case history
        /// The items of one pinboard, in the user's order.
        case pinboard(String)
    }

    public var list: List
    public var search: String
    public var kinds: Set<ItemKind>
    /// Source app bundle identifiers.
    public var apps: Set<String>
    public var devices: Set<String>
    public var date: DateFilter?
    /// Only items copied at or after this date (used by clippa-mcp).
    public var since: Date?
    /// Like Paste, a search looks across every list. Set to false to search
    /// only inside `list`.
    public var searchAllLists: Bool
    public var limit: Int
    public var offset: Int

    public init(list: List = .history, search: String = "", kinds: Set<ItemKind> = [],
                apps: Set<String> = [], devices: Set<String> = [], date: DateFilter? = nil,
                since: Date? = nil, searchAllLists: Bool = true, limit: Int = 200, offset: Int = 0) {
        self.list = list
        self.search = search
        self.kinds = kinds
        self.apps = apps
        self.devices = devices
        self.date = date
        self.since = since
        self.searchAllLists = searchAllLists
        self.limit = limit
        self.offset = offset
    }

    /// Search terms, split on spaces.
    public var terms: [String] {
        search.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// True when a search or a filter is active. Like Paste, a search looks
    /// across every list, not only the one on screen.
    public var isFiltering: Bool {
        !terms.isEmpty || !kinds.isEmpty || !apps.isEmpty || !devices.isEmpty || date != nil || since != nil
    }
}

/// The "date" search filter.
public enum DateFilter: String, Hashable, CaseIterable, Sendable {
    case today, yesterday, last7Days, last30Days

    public func range(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return startOfToday...now
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return start...startOfToday.addingTimeInterval(-0.001)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: startOfToday)!...now
        case .last30Days:
            return calendar.date(byAdding: .day, value: -29, to: startOfToday)!...now
        }
    }
}

/// An app that items were copied from, for the "app" filter.
public struct SourceApp: Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public var count: Int
}

/// A Mac that items were copied on, for the "device" filter.
public struct SourceDevice: Hashable, Sendable {
    public var id: String
    public var name: String
}
