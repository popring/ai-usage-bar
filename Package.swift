// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AIUsageBar",
            path: "Sources/AIUsageBar",
            // Single-process menu bar tool; all UI state lives on the main thread.
            // Swift 6 strict concurrency buys little and adds a lot of noise against
            // old AppKit APIs, so use the v5 language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
