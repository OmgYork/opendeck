// StreamDockHarness — 293V3 物理验证工具
//
// 用途:画满 15 键编号图(验证键位映射/图像链路),监听并打印按键事件(验证输入报告偏移)。
//       --plugin-test 跑插件宿主闭环冒烟(WS + node 进程 + 设备上屏,详见 PluginSmoke.swift)。
// 退出码:0 = 收到至少一个按键事件(插件模式:图像已上屏);2 = 未找到设备;3 = 窗口内无事件;4 = 前置失败。
//
// 用法:harness [--listen 秒] [--plugin-test <sdPlugin 目录>] [--node <node 路径>] [--key <0-14>]

import Foundation
import StreamDockKit

setbuf(stdout, nil) // 管道重定向时禁用块缓冲,事件实时可见

let arguments = CommandLine.arguments
func optionValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let listenSeconds: TimeInterval = {
    if let s = optionValue("--listen"), let seconds = Double(s) { return max(5, min(600, seconds)) }
    return 90
}()
let pluginTestDirectory = optionValue("--plugin-test").map { URL(fileURLWithPath: $0, isDirectory: true) }
let nodeOverride = optionValue("--node").map { URL(fileURLWithPath: $0) }
let keyIndex: Int = {
    if let raw = optionValue("--key"), let index = Int(raw), (0..<15).contains(index) { return index }
    return 7 // 默认 r1c2(面板第 8 键)
}()

let controller = DeviceController()
controller.onLog = { print("ℹ️  \($0)") }

// TRACE=1 时打印每个报文的前缀(与 coldtest --quick 的字节流做 diff 用)
if ProcessInfo.processInfo.environment["TRACE"] != nil {
    controller.enableWriteTrace { bytes in
        let hex = bytes.prefix(14).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("✍️  \(bytes.count)B: \(hex)")
    }
}

var eventCount = 0
controller.onKeyEvent = { event in
    eventCount += 1
    print("⌨️  r\(event.row)c\(event.column) \(event.phase == .down ? "按下" : "抬起")")
}

controller.start()

// 等待连接(最多 10s)
let connected: Bool = {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if controller.state == .running { return true }
    }
    return false
}()
guard connected else {
    print("❌ 未找到设备(退出码 2)")
    exit(2)
}

controller.setBrightness(80)

// 插件宿主闭环冒烟:接管后续流程,结束时直接退出
if let pluginTestDirectory {
    let code = runPluginSmoke(
        pluginDirectory: pluginTestDirectory,
        nodeOverride: nodeOverride,
        keyIndex: keyIndex,
        listenSeconds: listenSeconds,
        controller: controller
    )
    controller.shutdown()
    exit(code)
}

// 画满 15 键:顺序编号,验证键位映射与 UI 阅读顺序 1:1(左上 1,右下 15)
let palette = [
    "#BF616A", "#D08770", "#EBCB8B", "#A3BE8C", "#88C0D0",
    "#5E81AC", "#B48EAD", "#8FBCBB", "#D85886", "#EC9A5F",
    "#EFD48B", "#9FCB87", "#77B5C9", "#81A1C1", "#C69ABE",
]
for row in 0..<StreamDock293S.rows {
    for column in 0..<StreamDock293S.columns {
        let index = row * StreamDock293S.columns + column
        guard let image = IconRenderer.render(
            size: StreamDock293S.keySize(column: column),
            backgroundColorHex: palette[index % palette.count],
            title: "\(index + 1)"
        ) else {
            print("⚠️  r\(row)c\(column) 渲染失败")
            continue
        }
        // 首键落盘:发送内容与设备显示内容一致性的人工核对样本
        if index == 0, let jpeg = IconRenderer.jpeg(from: image) {
            try? jpeg.write(to: URL(fileURLWithPath: "/tmp/opendeck-key0.jpg"))
        }
        controller.drawKey(row: row, column: column, image: image)
    }
}
print("✅ 已画满 15 键 —— 面板编号 1-15 应与阅读顺序一一对应(左上 1,右下 15)")
print("—— 监听按键 \(Int(listenSeconds)) 秒,请在面板上按压任意键(6 个事件后提前结束)——")

let deadline = Date().addingTimeInterval(listenSeconds)
while Date() < deadline && eventCount < 6 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}

controller.shutdown()
if eventCount > 0 {
    print("✅ 共收到 \(eventCount) 个按键事件(退出码 0)")
    exit(0)
} else {
    print("⚠️  监听窗口内无按键(退出码 3)")
    exit(3)
}
