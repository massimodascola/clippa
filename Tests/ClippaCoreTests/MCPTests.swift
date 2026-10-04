@testable import ClippaCore
@testable import ClippaMCP
import XCTest

final class MCPTests: StoreTestCase {
    private var settings = MCPSettings(enabled: true, allowChanges: false)

    private func makeServer(_ store: ClippaStore) -> MCPServer {
        MCPServer(version: "test", settings: { [unowned self] in self.settings }, openStore: { store })
    }

    private func call(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let reply = try XCTUnwrap(server.handle(line: line))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func toolText(_ reply: [String: Any]) -> String {
        let result = reply["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    func testHandshakeAndToolList() throws {
        let server = makeServer(try makeStore())
        let initialize = try call(server, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                         "clientInfo": ["name": "test", "version": "1"]])
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))

        let tools = try call(server, "tools/list")
        let names = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["search_clipboard", "get_item", "list_pinboards"], "no write tools unless allowed")

        settings.allowChanges = true
        let more = try call(server, "tools/list")
        XCTAssertEqual(((more["result"] as? [String: Any])?["tools"] as? [Any])?.count, 6)

        let unknown = try call(server, "does/not/exist")
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testSearchAndRead() throws {
        let store = try makeStore()
        let item = try saveText("The launch is on Friday", in: store, app: "com.apple.Notes")
        try saveText("https://example.com/launch", in: store)
        let server = makeServer(store)

        let search = try call(server, "tools/call", ["name": "search_clipboard", "arguments": ["query": "launch"]])
        XCTAssertTrue(toolText(search).contains("\"count\" : 2"))
        let links = try call(server, "tools/call", ["name": "search_clipboard", "arguments": ["type": "link"]])
        XCTAssertTrue(toolText(links).contains("example.com"))
        let byApp = try call(server, "tools/call", ["name": "search_clipboard", "arguments": ["app": "notes"]])
        XCTAssertTrue(toolText(byApp).contains("Friday"))

        let read = try call(server, "tools/call", ["name": "get_item", "arguments": ["id": item.id]])
        XCTAssertTrue(toolText(read).contains("The launch is on Friday"))
    }

    func testSwitchesAreRespected() throws {
        let store = try makeStore()
        let server = makeServer(store)
        settings.enabled = false
        let off = try call(server, "tools/call", ["name": "search_clipboard", "arguments": [:]])
        XCTAssertEqual((off["result"] as? [String: Any])?["isError"] as? Bool, true)

        settings.enabled = true
        let refused = try call(server, "tools/call", ["name": "add_item", "arguments": ["text": "x"]])
        XCTAssertEqual((refused["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(try store.totalItemCount(), 0)

        settings.allowChanges = true
        _ = try call(server, "tools/call", ["name": "add_item", "arguments": ["text": "from Claude", "pinboard": "AI"]])
        XCTAssertEqual(try store.pinboards().map(\.name), ["AI"])
        XCTAssertEqual(try store.totalItemCount(), 1)
    }

    func testSinceParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(MCPServer.parseSince("7d", now: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(MCPServer.parseSince("2h", now: now), now.addingTimeInterval(-2 * 3_600))
        XCTAssertNotNil(MCPServer.parseSince("today", now: now))
        XCTAssertNotNil(MCPServer.parseSince("2026-10-01"))
        XCTAssertNil(MCPServer.parseSince("soon"))
    }
}
