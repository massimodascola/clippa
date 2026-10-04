// clippa-mcp: the Model Context Protocol server of Clippa.
//
// AI tools start it as a local process and exchange JSON-RPC messages with
// it, one per line, on stdin and stdout. It reads the same database as the
// app. Nothing goes over the network.
//
//   claude mcp add --scope user clippa -- /Applications/Clippa.app/Contents/MacOS/clippa-mcp
import ClippaCore
import ClippaMCP
import ClippaPasteboard
import Foundation

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

let server = MCPServer(
    version: version,
    settings: { MCPSettings.fromClippaPreferences() },
    openStore: {
        let defaults = ClippaPaths.sharedDefaults
        let deviceID = defaults.string(forKey: "deviceID") ?? "clippa-mcp"
        let deviceName = Host.current().localizedName ?? "Mac"
        let directory = ClippaPaths.dataDirectory
        guard FileManager.default.fileExists(atPath: ClippaPaths.databaseURL(in: directory).path) else {
            throw NSError(domain: "Clippa", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Clippa has not saved anything yet. Open Clippa first."])
        }
        return try ClippaStore(directory: directory, deviceID: deviceID, deviceName: deviceName)
    },
    copyToClipboard: { item, store in
        // Run on the main thread: NSPasteboard is happiest there.
        DispatchQueue.main.sync {
            PasteboardWriter.write([item], store: store, mode: .original)
        }
    }
)

// stdout carries protocol messages only; diagnostics go to stderr.
setvbuf(stdout, nil, _IOLBF, 0)

DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        if let reply = server.handle(line: line) {
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
    exit(0)
}

dispatchMain()
