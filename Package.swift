// swift-tools-version: 5.9
import PackageDescription

// Two targets, one seam. VantageCore is the half whose numbers must be provably right — parsing,
// money, dates, caching — and it imports nothing but Foundation, so `swift test` covers it without
// a window server or a menu bar. Vantage is the AppKit half, verified by eye.
let package = Package(
    name: "Vantage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Vantage", targets: ["Vantage"]),
        .executable(name: "vantage-cli", targets: ["VantageCLI"]),
    ],
    targets: [
        .target(name: "VantageCore"),
        .executableTarget(name: "Vantage", dependencies: ["VantageCore"]),
        // The agent-facing half. Read-only by construction: it links VantageCore, which is where
        // the cache lives, and nothing that can fetch or publish.
        //
        // Named `vantage-cli` rather than `vantage`: macOS filesystems are case-insensitive by
        // default, so a `vantage` binary and the app's `Vantage` binary are the same path and the
        // link step collides.
        .executableTarget(name: "VantageCLI", dependencies: ["VantageCore"],
                          path: "Sources/VantageCLI"),
        .testTarget(name: "VantageCoreTests", dependencies: ["VantageCore"]),
    ]
)
