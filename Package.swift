// swift-tools-version: 5.9
import PackageDescription

// Two targets, one seam. VantageCore is the half whose numbers must be provably right — parsing,
// money, dates, caching — and it imports nothing but Foundation, so `swift test` covers it without
// a window server or a menu bar. Vantage is the AppKit half, verified by eye.
let package = Package(
    name: "Vantage",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VantageCore"),
        .executableTarget(name: "Vantage", dependencies: ["VantageCore"]),
        .testTarget(name: "VantageCoreTests", dependencies: ["VantageCore"]),
    ]
)
