// coldtest — 293S 冷启动显示策略矩阵(独立于 StreamDockKit,复用探针的已验证链路)
//
// 流程:连设备 → 发一次 CONNECT 后静默 12s(无心跳)强制设备自重启 → 重新枚举 →
//       依次执行 7 种初始化策略,每种在面板中央列画大数字 0-6,保持 10s(期间心跳维持,并打印按键)
// 用户只需回报看到过哪些数字 → 定位冷设备需要的序列。
//
// 编译:swiftc -O coldtest.swift -o coldtest -framework IOKit -framework CoreGraphics -framework CoreText -framework ImageIO

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

setbuf(stdout, nil)

let vendorId = 0x6603
let productId = 0x1005
let packetSize = 1024
let maxKeyJPEGBytes = 10240
let cmdPrefix: [UInt8] = [0x43, 0x52, 0x54, 0x00, 0x00]

enum Cmd {
    static let heartbeat: [UInt8] = [0x43, 0x4f, 0x4e, 0x4e, 0x45, 0x43, 0x54]
    static let wake: [UInt8] = [0x44, 0x49, 0x53]
    static let refresh: [UInt8] = [0x53, 0x54, 0x50]
    static let clearPanel: [UInt8] = [0x43, 0x4c, 0x45, 0x00, 0x00, 0x00, 0xff]
    static func brightness(_ byte: UInt8) -> [UInt8] { [0x4c, 0x49, 0x47, 0x00, 0x00, byte] }
    static func drawKey(size: Int, key: UInt8) -> [UInt8] {
        [0x42, 0x41, 0x54,
         UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
         UInt8((size >> 8) & 0xff), UInt8(size & 0xff), key]
    }
}

let keyIds: [[UInt8]] = [
    [0x0d, 0x0a, 0x07, 0x04, 0x01, 0x10],
    [0x0e, 0x0b, 0x08, 0x05, 0x02, 0x11],
    [0x0f, 0x0c, 0x09, 0x06, 0x03, 0x12],
]

var device: IOHIDDevice?

func write(_ payload: [UInt8]) -> Bool {
    guard let dev = device else { return false }
    var bytes = payload
    let kr = bytes.withUnsafeMutableBufferPointer { buf in
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x00, buf.baseAddress!, buf.count)
    }
    if kr != kIOReturnSuccess {
        print(String(format: "⚠️ 写入失败 0x%08x", kr))
    } else if ProcessInfo.processInfo.environment["TRACE"] != nil {
        let hex = bytes.prefix(14).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("✍️  \(bytes.count)B: \(hex)")
    }
    return kr == kIOReturnSuccess
}

@discardableResult
func sendCmd(_ cmd: [UInt8]) -> Bool {
    var full = cmdPrefix + cmd
    full.append(contentsOf: [UInt8](repeating: 0, count: max(0, packetSize - full.count)))
    return write(Array(full.prefix(packetSize)))
}

func drawKey(_ key: UInt8, jpeg: Data) {
    sendCmd(Cmd.drawKey(size: jpeg.count, key: key))
    var offset = jpeg.startIndex
    while offset < jpeg.endIndex {
        let end = jpeg.index(offset, offsetBy: packetSize, limitedBy: jpeg.endIndex) ?? jpeg.endIndex
        var chunk = [UInt8](jpeg[offset..<end])
        chunk.append(contentsOf: [UInt8](repeating: 0, count: packetSize - chunk.count))
        write(chunk)
        offset = end
    }
    sendCmd(Cmd.refresh)
}

func makeJPEG(_ text: String, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
    let side = 100
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let font = CTFontCreateWithName((text.allSatisfy { $0.isASCII } ? "Helvetica-Bold" : "PingFang SC Semibold") as CFString, 58, nil)
    let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)]
    guard let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else { return nil }
    let line = CTLineCreateWithAttributedString(attrStr)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: (CGFloat(side) - width) / 2, y: CGFloat(side - 78))
    CTLineDraw(line, ctx)
    guard let image = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

func findDevice(vid: Int, pid: Int) -> IOHIDDevice? {
    guard let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)) as IOHIDManager? else { return nil }
    let match = [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid] as CFDictionary
    IOHIDManagerSetDeviceMatching(manager, match)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    CFRunLoopRunInMode(.defaultMode, 0.5, false)
    guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = set.first else { return nil }
    return dev
}

let inputCallback: IOHIDReportCallback = { _, _, _, _, _, report, reportLength in
    guard reportLength >= 11 else { return }
    let bytes = UnsafeBufferPointer(start: report, count: reportLength)
    print("⌨️  输入报告: key=0x\(String(bytes[9], radix: 16)) state=\(bytes[10])  [\(bytes.prefix(14).map { String(format: "%02x", $0) }.joined(separator: " "))]")
}

// MARK: - 主流程

// --quick:跳过强制重启矩阵,直接跑已验证的 V0 序列(用于与 Kit harness 做字节 diff)
if CommandLine.arguments.contains("--quick") {
    guard let dev = findDevice(vid: vendorId, pid: productId) else { print("❌ 未找到设备"); exit(2) }
    device = dev
    guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { print("❌ 打开失败"); exit(2) }
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    print("✅ 设备已打开(quick 模式)")
    sendCmd(Cmd.heartbeat)
    CFRunLoopRunInMode(.defaultMode, 0.1, false)
    sendCmd(Cmd.wake)
    sendCmd(Cmd.brightness(69))
    sendCmd(Cmd.clearPanel)
    if let jpeg = makeJPEG("7", red: 0.75, green: 0.25, blue: 0.25), jpeg.count <= maxKeyJPEGBytes {
        for row in 0..<3 { drawKey(keyIds[row][2], jpeg: jpeg) }
    }
    CFRunLoopRunInMode(.defaultMode, 8, false)
    sendCmd(Cmd.heartbeat)
    CFRunLoopRunInMode(.defaultMode, 5, false)
    sendCmd([0x43, 0x4c, 0x45, 0x00, 0x00, 0x44, 0x43])
    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    print("—— quick 结束(中央列应显示红色 7)——")
    exit(0)
}

guard let dev = findDevice(vid: vendorId, pid: productId) else {
    print("❌ 未找到设备"); exit(2)
}
device = dev
guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("❌ 打开失败"); exit(2)
}
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let inputLen = (IOHIDDeviceGetProperty(dev, "MaxInputReportSize" as CFString) as? Int) ?? 512
var inputBuffer = [UInt8](repeating: 0, count: inputLen + 1)
inputBuffer.withUnsafeMutableBufferPointer { buf in
    IOHIDDeviceRegisterInputReportCallback(dev, buf.baseAddress!, buf.count, inputCallback, nil)
}
print("✅ 设备已打开(0x6603:0x1005)")

// 阶段A:建立会话后静默 12s(无心跳)→ 强制设备自重启
print("—— 阶段A:发一次 CONNECT 后静默 12s,强制设备自重启 ——")
sendCmd(Cmd.heartbeat)
for tick in stride(from: 12, through: 2, by: -3) {
    print("   静默倒计时 \(tick)s…")
    CFRunLoopRunInMode(.defaultMode, 3.0, false)
}

// 阶段B:重新枚举(设备重启后 sessionID 会变)
print("—— 阶段B:等待设备重新枚举(最多 30s)——")
device = nil
var reopened: IOHIDDevice?
for _ in 0..<30 {
    CFRunLoopRunInMode(.defaultMode, 1.0, false)
    if let again = findDevice(vid: vendorId, pid: productId) {
        reopened = again
        break
    }
}
guard let fresh = reopened else { print("❌ 设备未重新出现"); exit(2) }
device = fresh
guard IOHIDDeviceOpen(fresh, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("❌ 重新打开失败"); exit(2)
}
IOHIDDeviceScheduleWithRunLoop(fresh, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
var buffer2 = [UInt8](repeating: 0, count: inputLen + 1)
buffer2.withUnsafeMutableBufferPointer { buf in
    IOHIDDeviceRegisterInputReportCallback(fresh, buf.baseAddress!, buf.count, inputCallback, nil)
}
print("✅ 设备已重新打开(冷状态)—— 下面开始策略矩阵,每策略画大数字,保持 10s")

let phaseColors: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("0", 0.75, 0.25, 0.25), ("1", 0.25, 0.75, 0.25), ("2", 0.25, 0.25, 0.75),
    ("3", 0.85, 0.85, 0.25), ("4", 0.85, 0.45, 0.15), ("5", 0.60, 0.30, 0.75),
    ("6", 0.20, 0.75, 0.75),
]

func drawPhase(_ digit: String, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
    guard let jpeg = makeJPEG(digit, red: r, green: g, blue: b), jpeg.count <= maxKeyJPEGBytes else { return }
    for row in 0..<3 {
        drawKey(keyIds[row][2], jpeg: jpeg)   // 中央列显示大数字
    }
}

func hold(seconds: Int, label: String) {
    var remaining = seconds
    while remaining > 0 {
        let chunk = min(5, remaining)
        CFRunLoopRunInMode(.defaultMode, Double(chunk), false)
        remaining -= chunk
        if remaining > 0 { sendCmd(Cmd.heartbeat) }  // 保持会话不重启
    }
    print("   [\(label)] 保持结束")
}

// V0 无停顿(当前 Kit 行为)
print("▶ V0 无停顿序列 → 数字 0(红)")
sendCmd(Cmd.heartbeat); sendCmd(Cmd.wake); sendCmd(Cmd.brightness(59)); sendCmd(Cmd.clearPanel)
drawPhase("0", phaseColors[0].1, phaseColors[0].2, phaseColors[0].3)
hold(seconds: 10, label: "V0")

// V1 有节奏(探针式停顿)
print("▶ V1 有节奏序列(300/300/500ms)→ 数字 1(绿)")
sendCmd(Cmd.clearPanel)
CFRunLoopRunInMode(.defaultMode, 0.3, false)
sendCmd(Cmd.heartbeat)
CFRunLoopRunInMode(.defaultMode, 0.3, false)
sendCmd(Cmd.wake)
CFRunLoopRunInMode(.defaultMode, 0.3, false)
sendCmd(Cmd.brightness(59))
CFRunLoopRunInMode(.defaultMode, 0.3, false)
sendCmd(Cmd.clearPanel)
CFRunLoopRunInMode(.defaultMode, 0.5, false)
drawPhase("1", phaseColors[1].1, phaseColors[1].2, phaseColors[1].3)
hold(seconds: 10, label: "V1")

// V2 先等 3s 再有节奏
print("▶ V2 冷静置 3s + V1 序列 → 数字 2(蓝)")
sendCmd(Cmd.clearPanel)
CFRunLoopRunInMode(.defaultMode, 3.0, false)
sendCmd(Cmd.heartbeat)
CFRunLoopRunInMode(.defaultMode, 0.3, false)
sendCmd(Cmd.wake)
CFRunLoopRunInMode(.defaultMode, 0.3, false)
sendCmd(Cmd.brightness(59))
sendCmd(Cmd.clearPanel)
CFRunLoopRunInMode(.defaultMode, 0.5, false)
drawPhase("2", phaseColors[2].1, phaseColors[2].2, phaseColors[2].3)
hold(seconds: 10, label: "V2")

// V3 双握手
print("▶ V3 双 CONNECT(间隔 1s)→ 数字 3(黄)")
sendCmd(Cmd.clearPanel)
sendCmd(Cmd.heartbeat)
CFRunLoopRunInMode(.defaultMode, 1.0, false)
sendCmd(Cmd.heartbeat)
CFRunLoopRunInMode(.defaultMode, 0.5, false)
sendCmd(Cmd.wake); sendCmd(Cmd.brightness(59)); sendCmd(Cmd.clearPanel)
CFRunLoopRunInMode(.defaultMode, 0.5, false)
drawPhase("3", phaseColors[3].1, phaseColors[3].2, phaseColors[3].3)
hold(seconds: 10, label: "V3")

// V4 跳过清屏
print("▶ V4 跳过 CLE → 数字 4(橙)")
sendCmd(Cmd.heartbeat)
CFRunLoopRunInMode(.defaultMode, 0.3, false)
sendCmd(Cmd.wake); sendCmd(Cmd.brightness(59))
CFRunLoopRunInMode(.defaultMode, 0.5, false)
drawPhase("4", phaseColors[4].1, phaseColors[4].2, phaseColors[4].3)
hold(seconds: 10, label: "V4")

// V5 亮度后置
print("▶ V5 亮度放在画图后 → 数字 5(紫)")
sendCmd(Cmd.clearPanel)
CFRunLoopRunInMode(.defaultMode, 0.5, false)
sendCmd(Cmd.heartbeat); sendCmd(Cmd.wake); sendCmd(Cmd.clearPanel)
CFRunLoopRunInMode(.defaultMode, 0.5, false)
drawPhase("5", phaseColors[5].1, phaseColors[5].2, phaseColors[5].3)
sendCmd(Cmd.brightness(59))
hold(seconds: 10, label: "V5")

// V6 持续心跳预热 6s 后再画
print("▶ V6 心跳预热 6s 后初始化 → 数字 6(青)")
sendCmd(Cmd.clearPanel)
for _ in 0..<2 {
    sendCmd(Cmd.heartbeat)
    CFRunLoopRunInMode(.defaultMode, 3.0, false)
}
sendCmd(Cmd.wake); sendCmd(Cmd.brightness(59)); sendCmd(Cmd.clearPanel)
CFRunLoopRunInMode(.defaultMode, 0.5, false)
drawPhase("6", phaseColors[6].1, phaseColors[6].2, phaseColors[6].3)
hold(seconds: 10, label: "V6")

sendCmd([0x43, 0x4c, 0x45, 0x00, 0x00, 0x44, 0x43]) // 干净关闭
IOHIDDeviceClose(device ?? dev, IOOptionBits(kIOHIDOptionsTypeNone))
print("—— 矩阵结束:请回报看到过哪些数字(0-6)与颜色,任意顺序 ——")
exit(0)
