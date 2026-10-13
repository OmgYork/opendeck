// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "OpenDeck",
    platforms: [.macOS(.v26)],
    targets: [
        // 驱动库:纯逻辑 + IOKit,可单测
        .target(
            name: "StreamDockKit",
            path: "Sources/StreamDockKit"
        ),
        // 插件宿主协议库:Elgato SD SDK v2 编解码 + manifest 解析(纯逻辑,可单测)
        .target(
            name: "PluginHost",
            path: "Sources/PluginHost"
        ),
        // CLI 验证工具:画满键位 + 打印按键事件 + 插件宿主冒烟
        .executableTarget(
            name: "StreamDockHarness",
            dependencies: ["StreamDockKit", "PluginHost"],
            path: "Sources/StreamDockHarness",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // 原生管理器应用(SwiftUI)
        .executableTarget(
            name: "OpenDeck",
            dependencies: ["StreamDockKit", "PluginHost"],
            path: "Sources/OpenDeck",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "StreamDockKitTests",
            dependencies: ["StreamDockKit"],
            path: "Tests/StreamDockKitTests"
        ),
        .testTarget(
            name: "PluginHostTests",
            dependencies: ["PluginHost"],
            path: "Tests/PluginHostTests"
        ),
    ]
)
