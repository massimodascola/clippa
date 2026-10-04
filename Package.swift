// swift-tools-version: 6.0
// Clippa is built with SwiftPM plus build.sh, which wraps the binaries into
// Clippa.app. No Xcode project is needed.
import PackageDescription

let package = Package(
    name: "Clippa",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Clippa", targets: ["Clippa"]),
        .executable(name: "clippa-mcp", targets: ["clippa-mcp"]),
        .library(name: "ClippaCore", targets: ["ClippaCore"]),
    ],
    targets: [
        // Storage, search, retention and sync. Foundation and SQLite only,
        // so the same code can back an iPhone or iPad app later.
        .target(name: "ClippaCore"),
        // Model Context Protocol server logic, kept apart from main.swift so
        // the tests can drive it without a process.
        .target(name: "ClippaMCP", dependencies: ["ClippaCore"]),
        // Writing items back to the macOS pasteboard, shared by the app and
        // clippa-mcp.
        .target(name: "ClippaPasteboard", dependencies: ["ClippaCore"]),
        .executableTarget(name: "clippa-mcp", dependencies: ["ClippaMCP", "ClippaPasteboard"]),
        // The macOS app.
        .executableTarget(name: "Clippa", dependencies: ["ClippaCore", "ClippaPasteboard"]),
        .testTarget(name: "ClippaCoreTests", dependencies: ["ClippaCore", "ClippaMCP"]),
    ],
    swiftLanguageModes: [.v5]
)
