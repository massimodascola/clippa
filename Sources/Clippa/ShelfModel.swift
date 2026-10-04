import AppKit
import ClippaCore
import Observation

/// A search filter shown as a token in the search field.
enum FilterToken: Hashable, Identifiable {
    case kind(ItemKind)
    case app(String, String)  // bundle id, name
    case device(String, String)  // id, name
    case date(DateFilter)

    var id: String {
        switch self {
        case .kind(let kind): return "kind:\(kind.rawValue)"
        case .app(let id, _): return "app:\(id)"
        case .device(let id, _): return "device:\(id)"
        case .date(let date): return "date:\(date.rawValue)"
        }
    }

    var label: String {
        switch self {
        case .kind(let kind): return kind.pluralName
        case .app(_, let name): return name
        case .device(_, let name): return name
        case .date(let date): return date.name
        }
    }

    var symbol: String {
        switch self {
        case .kind(let kind): return kind.symbol
        case .app: return "app"
        case .device: return "laptopcomputer"
        case .date: return "calendar"
        }
    }
}

extension ItemKind {
    var name: String {
        switch self {
        case .text: return L("Text")
        case .link: return L("Link")
        case .image: return L("Image")
        case .file: return L("File")
        case .color: return L("Color")
        }
    }

    var pluralName: String {
        switch self {
        case .text: return L("Text")
        case .link: return L("Links")
        case .image: return L("Images")
        case .file: return L("Files")
        case .color: return L("Colors")
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }
}

extension DateFilter {
    var name: String {
        switch self {
        case .today: return L("Today")
        case .yesterday: return L("Yesterday")
        case .last7Days: return L("Last 7 Days")
        case .last30Days: return L("Last 30 Days")
        }
    }
}

/// What the shelf shows and what the user is doing with it.
@MainActor
@Observable
final class ShelfModel {
    let store: ClippaStore
    weak var controller: ShelfController?

    var list: ItemQuery.List = .history
    var pinboards: [Pinboard] = []
    private(set) var items: [Item] = []
    private(set) var hasMore = false
    private var pageSize = 150

    /// Selected item ids, in the order they were selected.
    var selection: [String] = []
    private var anchorID: String?

    var searchText = "" { didSet { if searchText != oldValue { scheduleReload() } } }
    var filters: [FilterToken] = [] { didSet { reload() } }
    var searchFocused = false

    var showingSuggestions = false
    var suggestions: [Item] = []
    var suggestionsLoading = false

    /// True while the Quick Paste modifier is held: cards show their numbers.
    var showNumbers = false
    var firstVisibleIndex = 0
    var renamingID: String?
    var editingPinboardID: String?
    var creatingPinboard = false
    var previewID: String?
    var scrollTarget: String?
    var toast: String?
    var compact = false

    private var undoStack: [[Item]] = []
    private var reloadWork: DispatchWorkItem?

    init(store: ClippaStore) {
        self.store = store
    }

    // MARK: - Loading

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !filters.isEmpty
    }

    var visibleItems: [Item] {
        showingSuggestions && !isSearching ? suggestions : items
    }

    var currentPinboard: Pinboard? {
        if case .pinboard(let id) = list { return pinboards.first { $0.id == id } }
        return nil
    }

    private var query: ItemQuery {
        var query = ItemQuery(list: list, search: searchText, limit: pageSize)
        for filter in filters {
            switch filter {
            case .kind(let kind): query.kinds.insert(kind)
            case .app(let id, _): query.apps.insert(id)
            case .device(let id, _): query.devices.insert(id)
            case .date(let date): query.date = date
            }
        }
        return query
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Reloads from the store, keeping the selection where possible.
    func reload(keepingCount: Bool = true) {
        pinboards = (try? store.pinboards()) ?? []
        if case .pinboard(let id) = list, !pinboards.contains(where: { $0.id == id }) {
            list = .history
        }
        var query = self.query
        if keepingCount { query.limit = max(pageSize, items.count) }
        let loaded = (try? store.items(matching: query)) ?? []
        items = loaded
        hasMore = loaded.count == query.limit
        if showingSuggestions {
            let ids = Set(suggestions.map(\.id))
            suggestions = (try? store.items(ids: suggestions.map(\.id)))?.filter { ids.contains($0.id) } ?? suggestions
        }
        let visible = Set(visibleItems.map(\.id))
        selection = selection.filter(visible.contains)
        if selection.isEmpty, let first = visibleItems.first {
            selection = [first.id]
            anchorID = first.id
        }
    }

    func loadMore() {
        guard hasMore else { return }
        var query = self.query
        query.offset = items.count
        let more = (try? store.items(matching: query)) ?? []
        items += more
        hasMore = more.count == query.limit
    }

    /// Called when the shelf opens.
    func prepareForShow() {
        searchText = ""
        filters = []
        searchFocused = false
        renamingID = nil
        previewID = nil
        showNumbers = false
        creatingPinboard = false
        editingPinboardID = nil
        undoStack = []
        selection = []
        reload(keepingCount: false)
        if let first = visibleItems.first {
            selection = [first.id]
            anchorID = first.id
            scrollTarget = first.id
        }
    }

    func show(list newList: ItemQuery.List) {
        list = newList
        searchText = ""
        filters = []
        showingSuggestions = false
        selection = []
        reload(keepingCount: false)
        scrollTarget = visibleItems.first?.id
    }

    // MARK: - Selection

    var selectedItems: [Item] {
        let byID = Dictionary(visibleItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selection.compactMap { byID[$0] }
    }

    /// The selected items in the order they appear on the shelf.
    var selectedItemsInOrder: [Item] {
        let selected = Set(selection)
        return visibleItems.filter { selected.contains($0.id) }
    }

    func click(_ item: Item, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if let index = selection.firstIndex(of: item.id), selection.count > 1 {
                selection.remove(at: index)
            } else if !selection.contains(item.id) {
                selection.append(item.id)
            }
            anchorID = item.id
        } else if modifiers.contains(.shift), let anchorID {
            selectRange(from: anchorID, to: item.id)
        } else {
            selection = [item.id]
            anchorID = item.id
        }
    }

    private func selectRange(from start: String, to end: String) {
        let ids = visibleItems.map(\.id)
        guard let a = ids.firstIndex(of: start), let b = ids.firstIndex(of: end) else { return }
        selection = Array(ids[min(a, b)...max(a, b)])
    }

    func moveSelection(by offset: Int, extend: Bool) {
        let ids = visibleItems.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.last.flatMap { ids.firstIndex(of: $0) } ?? -1
        let next = max(0, min(ids.count - 1, current + offset))
        if extend, let anchorID {
            selectRange(from: anchorID, to: ids[next])
            // Keep the moving end last so the next step continues from it.
            selection.removeAll { $0 == ids[next] }
            selection.append(ids[next])
        } else {
            selection = [ids[next]]
            anchorID = ids[next]
        }
        scrollTarget = ids[next]
        if next >= ids.count - 10 { loadMore() }
    }

    func selectEdge(last: Bool) {
        if last { while hasMore { loadMore() } }
        guard let id = last ? visibleItems.last?.id : visibleItems.first?.id else { return }
        selection = [id]
        anchorID = id
        scrollTarget = id
    }

    func selectAll() {
        while hasMore { loadMore() }
        selection = visibleItems.map(\.id)
    }

    // MARK: - Actions on items

    func pasteSelection(plainText: Bool) {
        let chosen = selectedItemsInOrder
        guard !chosen.isEmpty else { return }
        controller?.paste(chosen, plainText: plainText)
    }

    func quickPaste(number: Int, plainText: Bool) {
        let index = firstVisibleIndex + number - 1
        guard visibleItems.indices.contains(index) else { return }
        controller?.paste([visibleItems[index]], plainText: plainText)
    }

    func copySelection() {
        guard controller?.copy(selectedItemsInOrder) == true else { return }
        flash(L("Copied"))
    }

    func deleteSelection() {
        let ids = selectedItemsInOrder.map(\.id)
        guard !ids.isEmpty else { return }
        let ordered = visibleItems.map(\.id)
        let firstIndex = ordered.firstIndex(of: ids[0]) ?? 0
        if let removed = try? store.delete(ids: ids), !removed.isEmpty {
            undoStack.append(removed)
        }
        suggestions.removeAll { ids.contains($0.id) }
        selection = []
        reload()
        let remaining = visibleItems
        if !remaining.isEmpty {
            let id = remaining[min(firstIndex, remaining.count - 1)].id
            selection = [id]
            anchorID = id
        }
        controller?.storeDidChange()
    }

    func undo() {
        guard let items = undoStack.popLast() else { return }
        try? store.restore(items)
        reload()
        selection = items.map(\.id)
        scrollTarget = items.first?.id
        controller?.storeDidChange()
    }

    func rename(_ id: String, to title: String) {
        try? store.setTitle(title, for: id)
        renamingID = nil
        reload()
        controller?.storeDidChange()
    }

    func pin(_ ids: [String], to pinboardID: String?) {
        try? store.pin(ids, to: pinboardID)
        reload()
        if let pinboardID, let name = pinboards.first(where: { $0.id == pinboardID })?.name {
            flash(L("Pinned to %@", name))
        }
        controller?.storeDidChange()
    }

    func setKeep(_ choice: KeepChoice, for ids: [String]) {
        try? store.setKeep(choice.rule(), for: ids)
        reload()
        controller?.storeDidChange()
    }

    func createTextItem() {
        let pinboardID: String?
        if case .pinboard(let id) = list { pinboardID = id } else { pinboardID = nil }
        guard let item = try? store.createTextItem("", pinboardID: pinboardID) else { return }
        reload()
        selection = [item.id]
        scrollTarget = item.id
        controller?.edit(item)
    }

    /// Command-G: leave the search and show the item where it lives.
    func showSelectedInList() {
        guard selection.count == 1, let item = selectedItems.first else { return }
        let target: ItemQuery.List = item.inHistory ? .history : (item.pinboardID.map { .pinboard($0) } ?? .history)
        searchText = ""
        filters = []
        showingSuggestions = false
        list = target
        reload(keepingCount: false)
        while !items.contains(where: { $0.id == item.id }) && hasMore { loadMore() }
        selection = [item.id]
        anchorID = item.id
        scrollTarget = item.id
    }

    func moveInPinboard(_ id: String, before targetID: String) {
        guard case .pinboard(let pinboardID) = list, id != targetID,
              let index = items.firstIndex(where: { $0.id == targetID }) else { return }
        try? store.move(id, toIndex: index, in: pinboardID)
        reload()
        controller?.storeDidChange()
    }

    // MARK: - Pinboards

    func createPinboard(name: String, color: PinboardColor) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        creatingPinboard = false
        guard !trimmed.isEmpty, let pinboard = try? store.createPinboard(name: trimmed, color: color) else { return }
        reload()
        show(list: .pinboard(pinboard.id))
        controller?.storeDidChange()
    }

    func renamePinboard(_ id: String, to name: String) {
        editingPinboardID = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var pinboard = pinboards.first(where: { $0.id == id }) else { return }
        pinboard.name = trimmed
        try? store.savePinboard(pinboard)
        reload()
        controller?.storeDidChange()
    }

    func setColor(_ color: PinboardColor, of id: String) {
        guard var pinboard = pinboards.first(where: { $0.id == id }) else { return }
        pinboard.color = color
        try? store.savePinboard(pinboard)
        reload()
        controller?.storeDidChange()
    }

    func deletePinboard(_ id: String) {
        try? store.deletePinboard(id: id)
        if list == .pinboard(id) { list = .history }
        reload(keepingCount: false)
        controller?.storeDidChange()
    }

    func movePinboard(_ id: String, before targetID: String?) {
        var ids = pinboards.map(\.id)
        ids.removeAll { $0 == id }
        let index = targetID.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(id, at: index)
        try? store.reorderPinboards(ids)
        reload()
        controller?.storeDidChange()
    }

    /// Command-Right / Command-Left: next or previous list.
    func switchList(by offset: Int) {
        let lists: [ItemQuery.List] = [.history] + pinboards.map { .pinboard($0.id) }
        let current = lists.firstIndex(of: list) ?? 0
        let next = (current + offset + lists.count) % lists.count
        show(list: lists[next])
    }

    // MARK: - Search

    /// Filters that match the word being typed, offered as tokens.
    var filterSuggestions: [FilterToken] {
        guard let word = searchText.split(separator: " ").last.map(String.init), word.count >= 2,
              !searchText.hasSuffix(" ") else { return [] }
        var tokens: [FilterToken] = []
        for kind in ItemKind.allCases where kind.pluralName.localizedCaseInsensitiveContains(word)
            || kind.name.localizedCaseInsensitiveContains(word) || kind.rawValue.localizedCaseInsensitiveContains(word) {
            tokens.append(.kind(kind))
        }
        for date in DateFilter.allCases where date.name.localizedCaseInsensitiveContains(word) {
            tokens.append(.date(date))
        }
        for app in (try? store.sourceApps()) ?? [] where app.name.localizedCaseInsensitiveContains(word) {
            tokens.append(.app(app.bundleID, app.name))
        }
        let devices = (try? store.devices()) ?? []
        if devices.count > 1 {
            for device in devices where device.name.localizedCaseInsensitiveContains(word) {
                tokens.append(.device(device.id, device.name))
            }
        }
        return Array(tokens.filter { !filters.contains($0) }.prefix(6))
    }

    func apply(_ token: FilterToken) {
        var words = searchText.split(separator: " ").map(String.init)
        if !words.isEmpty, !searchText.hasSuffix(" ") { words.removeLast() }
        searchText = words.joined(separator: " ")
        if case .date = token { filters.removeAll { if case .date = $0 { return true } else { return false } } }
        if !filters.contains(token) { filters.append(token) }
    }

    func remove(_ token: FilterToken) {
        filters.removeAll { $0 == token }
    }

    var allFilterOptions: (apps: [SourceApp], devices: [SourceDevice]) {
        ((try? store.sourceApps()) ?? [], (try? store.devices()) ?? [])
    }

    func clearSearch() {
        searchText = ""
        filters = []
        searchFocused = false
    }

    // MARK: - Feedback

    func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }
}
