// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AIUsageBar",
            path: "Sources/AIUsageBar",
            // 本项目是单进程的菜单栏小工具，全部 UI 状态都在主线程上。
            // Swift 6 严格并发对 AppKit 这类老 API 的收益很低、噪音很大，故用 v5 语言模式。
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
