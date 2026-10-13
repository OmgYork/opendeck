// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MiraDeck",
    platforms: [.macOS(.v14)],
    targets: [
        // 驱动库:纯逻辑 + IOKit,可单测
        .target(
            name: "StreamDockKit",
            path: "Sources/StreamDockKit"
        ),
        // CLI 验证工具:画满键位 + 打印按键事件
        .executableTarget(
            name: "StreamDockHarness",
            dependencies: ["StreamDockKit"],
            path: "Sources/StreamDockHarness",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "StreamDockKitTests",
            dependencies: ["StreamDockKit"],
            path: "Tests/StreamDockKitTests"
        ),
    ]
)
