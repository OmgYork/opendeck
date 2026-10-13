// StreamDockHarness — 293S 物理验证工具
//
// 用途:画满 18 键编号图(验证键位映射/图像链路),监听并打印按键事件(验证输入报告偏移)。
// 退出码:0 = 收到至少一个按键事件;2 = 未找到设备;3 = 监听窗口内无按键。
//
// 用法:harness [--listen 秒](默认 90)

import Foundation
import StreamDockKit

setbuf(stdout, nil) // 管道重定向时禁用块缓冲,事件实时可见

let arguments = CommandLine.arguments
let listenSeconds: TimeInterval
if let index = arguments.firstIndex(of: "--listen"), index + 1 < arguments.count, let s = Double(arguments[index + 1]) {
    listenSeconds = max(5, min(600, s))
} else {
    listenSeconds = 90
}

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
    let kind = event.column == 5 ? "软键" : "主键"
    print("⌨️  r\(event.row)c\(event.column) \(kind) \(event.phase == .down ? "按下" : "抬起")")
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
    print("❌ 未找到 293S 设备(退出码 2)")
    exit(2)
}

controller.setBrightness(80)

// 画满 18 键:编号 + 方向三角(箭头朝上,若面板上显示为横向则说明 LCD 旋转,需在渲染层加 90° 校正)
let palette = [
    "#BF616A", "#D08770", "#EBCB8B", "#A3BE8C", "#88C0D0",
    "#5E81AC", "#B48EAD", "#8FBCBB", "#D85886", "#EC9A5F",
    "#EFD48B", "#9FCB87", "#77B5C9", "#81A1C1", "#C69ABE",
    "#4C566A", "#434C5E", "#3B4252",
]
for row in 0..<StreamDock293S.rows {
    for column in 0..<StreamDock293S.columns {
        let index = row * StreamDock293S.columns + column
        let title = column == 5 ? "S\(row + 1)" : "\(index + 1)"
        guard let image = IconRenderer.render(
            size: StreamDock293S.keySize(column: column),
            backgroundColorHex: palette[index % palette.count],
            title: title
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
print("✅ 已画满 18 键 —— 请查看面板:编号应为 1-15 + S1-S3,全部箭头朝上")
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
