import ClippaCore
import Foundation

/// What the user allowed in Clippa Settings → Intelligence.
public struct MCPSettings: Sendable {
    public var enabled: Bool
    public var allowChanges: Bool

    public init(enabled: Bool, allowChanges: Bool) {
        self.enabled = enabled
        self.allowChanges = allowChanges
    }

    /// Reads the switches from the app's preferences.
    public static func fromClippaPreferences() -> MCPSettings {
        let defaults = ClippaPaths.sharedDefaults
        return MCPSettings(enabled: defaults.bool(forKey: "mcpEnabled"),
                           allowChanges: defaults.bool(forKey: "mcpAllowChanges"))
    }
}

/// A Model Context Protocol server over JSON-RPC 2.0, one message per line.
/// It lets AI tools (Claude Code, Claude Desktop, Cursor...) search the
/// clipboard history. Everything stays on this Mac: the AI tool starts
/// clippa-mcp as a local process and talks to it through stdin/stdout.
public final class MCPServer {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let openStore: () throws -> ClippaStore
    private let settings: () -> MCPSettings
    private let copyToClipboard: ((Item, ClippaStore) -> Bool)?
    private let version: String
    private var store: ClippaStore?

    public init(version: String, settings: @escaping () -> MCPSettings,
                openStore: @escaping () throws -> ClippaStore,
                copyToClipboard: ((Item, ClippaStore) -> Bool)? = nil) {
        self.version = version
        self.settings = settings
        self.openStore = openStore
        self.copyToClipboard = copyToClipboard
    }

    /// Handles one incoming line and returns the reply line, if any.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(),
                           "error": ["code": -32700, "message": "Parse error"]])
        }
        if let batch = object as? [[String: Any]] {
            let replies = batch.compactMap(reply(to:))
            return replies.isEmpty ? nil : encode(replies)
        }
        guard let message = object as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(),
                           "error": ["code": -32600, "message": "Invalid request"]])
        }
        return reply(to: message).flatMap(encode)
    }

    private func reply(to message: [String: Any]) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil } // a response: ignore
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        guard id != nil else { return nil } // notifications need no reply

        func result(_ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": value] }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id!, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.supportedVersions[0]
            let chosen = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return result([
                "protocolVersion": chosen,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "clippa", "title": "Clippa", "version": version],
                "instructions": """
                Clippa is the user's clipboard manager on this Mac. Use search_clipboard to find \
                things the user copied (text, links, images, files, colors), get_item to read one \
                in full, and list_pinboards for the collections they keep. Dates are local time.
                """,
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": toolDefinitions()])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(callTool(name, arguments))
        case "resources/list":
            return result(["resources": [Any]()])
        case "prompts/list":
            return result(["prompts": [Any]()])
        default:
            return error(-32601, "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    private func toolDefinitions() -> [[String: Any]] {
        let kinds = ItemKind.allCases.map(\.rawValue)
        var tools: [[String: Any]] = [
            [
                "name": "search_clipboard",
                "title": "Search clipboard history",
                "description": """
                Search everything the user copied on this Mac, newest first. With no query, lists \
                the most recent items. Matches any part of a word, in text, titles, link titles, \
                app names and text recognized in images.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words to look for. Leave empty for the latest items."],
                        "type": ["type": "string", "enum": kinds, "description": "Only this kind of item."],
                        "app": ["type": "string", "description": "Only items copied from this app (name, e.g. \"Safari\")."],
                        "pinboard": ["type": "string", "description": "Only items in this pinboard (name or id)."],
                        "since": ["type": "string", "description": "Only items copied since: \"today\", \"yesterday\", \"7d\", \"30d\", or an ISO 8601 date."],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many items (default 20)."],
                    ],
                ],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "get_item",
                "title": "Read a clipboard item",
                "description": "Return one item in full: the whole text, the link, the file paths, or the image (with any text recognized in it).",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Item id from search_clipboard."]],
                    "required": ["id"],
                ],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "list_pinboards",
                "title": "List pinboards",
                "description": "List the user's pinboards (named collections of items kept forever) with their item counts.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
        ]
        guard settings().allowChanges else { return tools }
        tools += [
            [
                "name": "add_item",
                "title": "Add a text item",
                "description": "Save a new text item in Clippa, in the clipboard history or directly in a pinboard.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "title": ["type": "string", "description": "Optional label shown on the card."],
                        "pinboard": ["type": "string", "description": "Pinboard name or id. Omit to add to the history."],
                    ],
                    "required": ["text"],
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
            ],
            [
                "name": "pin_item",
                "title": "Pin an item",
                "description": "Move an item into a pinboard. The pinboard is created if it does not exist.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "pinboard": ["type": "string", "description": "Pinboard name or id."],
                    ],
                    "required": ["id", "pinboard"],
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
            ],
            [
                "name": "copy_to_clipboard",
                "title": "Put an item on the clipboard",
                "description": "Copy an item back to the system clipboard, so the user can paste it with Command-V.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
            ],
        ]
        return tools
    }

    private func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let current = settings()
        guard current.enabled else {
            return toolError("Clippa's MCP access is turned off. The user can turn it on in Clippa Settings → Intelligence → AI tools.")
        }
        do {
            let store = try currentStore()
            switch name {
            case "search_clipboard": return try search(arguments, store: store)
            case "get_item": return try getItem(arguments, store: store)
            case "list_pinboards": return try listPinboards(store: store)
            case "add_item", "pin_item", "copy_to_clipboard":
                guard current.allowChanges else {
                    return toolError("Changes are not allowed. The user can allow them in Clippa Settings → Intelligence → AI tools.")
                }
                switch name {
                case "add_item": return try addItem(arguments, store: store)
                case "pin_item": return try pinItem(arguments, store: store)
                default: return try copyItem(arguments, store: store)
                }
            default:
                return toolError("Unknown tool: \(name)")
            }
        } catch {
            return toolError("Clippa could not read its data: \(error)")
        }
    }

    private func currentStore() throws -> ClippaStore {
        if let store { return store }
        let opened = try openStore()
        store = opened
        return opened
    }

    private func search(_ arguments: [String: Any], store: ClippaStore) throws -> [String: Any] {
        var query = ItemQuery(search: arguments["query"] as? String ?? "")
        query.limit = min(max((arguments["limit"] as? Int) ?? 20, 1), 100)
        if let type = arguments["type"] as? String {
            guard let kind = ItemKind(rawValue: type) else { return toolError("Unknown type \(type).") }
            query.kinds = [kind]
        }
        if let app = arguments["app"] as? String, !app.isEmpty {
            let matches = try store.sourceApps().filter {
                $0.name.localizedCaseInsensitiveContains(app) || $0.bundleID.localizedCaseInsensitiveContains(app)
            }
            guard !matches.isEmpty else { return text("No items copied from an app matching \"\(app)\".") }
            query.apps = Set(matches.map(\.bundleID))
        }
        if let name = arguments["pinboard"] as? String, !name.isEmpty {
            guard let pinboard = try findPinboard(name, store: store) else {
                return toolError("No pinboard named \"\(name)\". Use list_pinboards to see them.")
            }
            query.list = .pinboard(pinboard.id)
            query.searchAllLists = false
        }
        if let since = arguments["since"] as? String, !since.isEmpty {
            guard let date = Self.parseSince(since) else {
                return toolError("Could not read since=\"\(since)\". Use today, yesterday, 7d, 30d or an ISO 8601 date.")
            }
            query.since = date
        }
        let items = try store.items(matching: query)
        let pinboards = Dictionary(try store.pinboards().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let summaries = items.map { summary(of: $0, pinboards: pinboards) }
        return text(json(["count": summaries.count, "items": summaries]))
    }

    private func getItem(_ arguments: [String: Any], store: ClippaStore) throws -> [String: Any] {
        guard let id = arguments["id"] as? String, let item = try store.item(id: id) else {
            return toolError("No item with that id.")
        }
        let pinboards = Dictionary(try store.pinboards().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var details = summary(of: item, pinboards: pinboards)
        details.removeValue(forKey: "preview")
        var content: [[String: Any]] = []
        switch item.kind {
        case .text, .link, .color:
            var full = fullText(of: item, store: store)
            if full.count > 200_000 {
                full = String(full.prefix(200_000))
                details["truncated"] = true
            }
            details["text"] = full
        case .file:
            details["files"] = item.text.components(separatedBy: "\n")
        case .image:
            if let ocr = item.ocrText, !ocr.isEmpty { details["recognized_text"] = ocr }
            if let image = imageData(of: item, store: store) {
                content.append(["type": "image", "data": image.data.base64EncodedString(), "mimeType": image.mime])
            }
        }
        content.insert(["type": "text", "text": json(details)], at: 0)
        return ["content": content]
    }

    private func listPinboards(store: ClippaStore) throws -> [String: Any] {
        let counts = try store.pinboardItemCounts()
        let list = try store.pinboards().map { pinboard -> [String: Any] in
            ["id": pinboard.id, "name": pinboard.name, "color": "\(pinboard.color)", "items": counts[pinboard.id] ?? 0]
        }
        return text(json(["pinboards": list]))
    }

    private func addItem(_ arguments: [String: Any], store: ClippaStore) throws -> [String: Any] {
        guard let body = arguments["text"] as? String, !body.isEmpty else { return toolError("text is required.") }
        var pinboardID: String?
        if let name = arguments["pinboard"] as? String, !name.isEmpty {
            pinboardID = try (findPinboard(name, store: store) ?? store.createPinboard(name: name, color: .blue)).id
        }
        let item = try store.createTextItem(body, title: arguments["title"] as? String, pinboardID: pinboardID)
        ClippaSignal.post()
        return text(json(["added": item.id]))
    }

    private func pinItem(_ arguments: [String: Any], store: ClippaStore) throws -> [String: Any] {
        guard let id = arguments["id"] as? String, try store.item(id: id) != nil else { return toolError("No item with that id.") }
        guard let name = arguments["pinboard"] as? String, !name.isEmpty else { return toolError("pinboard is required.") }
        let pinboard = try findPinboard(name, store: store) ?? store.createPinboard(name: name, color: .blue)
        try store.pin([id], to: pinboard.id)
        ClippaSignal.post()
        return text(json(["pinned": id, "pinboard": pinboard.name]))
    }

    private func copyItem(_ arguments: [String: Any], store: ClippaStore) throws -> [String: Any] {
        guard let id = arguments["id"] as? String, let item = try store.item(id: id) else { return toolError("No item with that id.") }
        guard let copyToClipboard, copyToClipboard(item, store) else {
            return toolError("Could not write to the clipboard.")
        }
        try store.markCopied(id)
        ClippaSignal.post()
        return text("Copied to the clipboard. The user can paste it with Command-V.")
    }

    // MARK: - Helpers

    private func findPinboard(_ nameOrID: String, store: ClippaStore) throws -> Pinboard? {
        let all = try store.pinboards()
        return all.first { $0.id == nameOrID }
            ?? all.first { $0.name.compare(nameOrID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private func summary(of item: Item, pinboards: [String: String]) -> [String: Any] {
        var summary: [String: Any] = [
            "id": item.id,
            "type": item.kind.rawValue,
            "copied": Self.dateFormatter.string(from: item.copiedAt),
            "preview": String(item.text.prefix(300)),
        ]
        if let title = item.title { summary["title"] = title }
        if let app = item.sourceAppName { summary["app"] = app }
        if let pinboard = item.pinboardID.flatMap({ pinboards[$0] }) { summary["pinboard"] = pinboard }
        if let linkTitle = item.linkTitle { summary["link_title"] = linkTitle }
        if item.kind == .image {
            if let width = item.imageWidth, let height = item.imageHeight { summary["size"] = "\(width)×\(height)" }
            if let ocr = item.ocrText, !ocr.isEmpty { summary["preview"] = String(ocr.prefix(300)) }
        }
        if item.kind == .text { summary["characters"] = item.text.count }
        return summary
    }

    private func fullText(of item: Item, store: ClippaStore) -> String {
        let plain = item.representations.first { $0.type == UTI.plainText || $0.type == UTI.string }
        if let plain, let data = store.blobs.read(plain.blob), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return item.text
    }

    private func imageData(of item: Item, store: ClippaStore) -> (data: Data, mime: String)? {
        // Prefer the original PNG or JPEG if it is not too heavy for a chat.
        let limit = 1_500_000
        for (type, mime) in [(UTI.png, "image/png"), (UTI.jpeg, "image/jpeg")] {
            if let rep = item.representations.first(where: { $0.type == type }), rep.size <= limit,
               let data = store.blobs.read(rep.blob) {
                return (data, mime)
            }
        }
        if let thumbnail = item.thumbnail, let data = store.blobs.read(thumbnail) {
            return (data, "image/png")
        }
        return nil
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseSince(_ value: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch lowered {
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default: break
        }
        if lowered.hasSuffix("d"), let days = Int(lowered.dropLast()), days > 0 {
            return now.addingTimeInterval(-Double(days) * 86_400)
        }
        if lowered.hasSuffix("h"), let hours = Int(lowered.dropLast()), hours > 0 {
            return now.addingTimeInterval(-Double(hours) * 3_600)
        }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: value) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        return day.date(from: value)
    }

    private func text(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]]]
    }

    private func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func encode(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
