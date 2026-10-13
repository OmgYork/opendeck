// StreamDockProbe — MiraBox Stream Dock 293S 直接控制探针(macOS,零第三方依赖)
//
// 设备:HOTSPOTEKUSB HID DEMO,VID 0x6603 PID 0x1005(ioreg 实测)
// 协议依据:bitfocus/companion-surface-mirabox-stream-dock(MIT)src/streamdock.ts 实测可读实现:
//   - 所有命令:输出报告(reportID 0),载荷 = "CRT\0\0" + 命令字节,补零到 packetSize(1024,部分型号 512)
//   - 命令为 ASCII 助记符:CONNECT(心跳,8s 内必须发,否则设备重启)/ DIS(唤醒)/ STP(刷新)
//     / LIG 0 0 b(亮度,b=(v/100)^0.75*100)/ CLE 0 0 id(清单键,0xff=整板)/ BAT size32BE keyId(画键,后跟 JPEG 原始块)
//   - 图像:JPEG RGB,主键 100×100、软键 80×80,单键 ≤10240 字节,按 1024 字节分块发送(无 CRT 前缀),最后 STP
//   - 按键事件:输入报告 data[9]=键 id,data[10]=0 抬起 / 非0 按下
//   - 键位映射(蛇形走线):r0:[0d 0a 07 04 01] r1:[0e 0b 08 05 02] r2:[0f 0c 09 06 03] 软键:[10 11 12]
//
// 编译:swiftc -O StreamDockProbe.swift -o probe -framework IOKit -framework CoreGraphics -framework CoreText -framework ImageIO

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let vendorId = 0x6603
let productId = 0x1005
let maxKeyJPEGBytes = 10240

let cmdPrefix: [UInt8] = [0x43, 0x52, 0x54, 0x00, 0x00] // "CRT"

enum Cmd {
    static let heartbeat: [UInt8] = [0x43, 0x4f, 0x4e, 0x4e, 0x45, 0x43, 0x54]              // CONNECT
    static let wake: [UInt8] = [0x44, 0x49, 0x53]                                           // DIS
    static let refresh: [UInt8] = [0x53, 0x54, 0x50]                                        // STP
    static let clearPanel: [UInt8] = [0x43, 0x4c, 0x45, 0x00, 0x00, 0x00, 0xff]             // CLE .. 0xff
    static let close: [UInt8] = [0x43, 0x4c, 0x45, 0x00, 0x00, 0x44, 0x43]                  // CLE .. "DC"
    static func brightness(_ byte: UInt8) -> [UInt8] { [0x4c, 0x49, 0x47, 0x00, 0x00, byte] } // LIG
    static func drawKey(size: Int, key: UInt8) -> [UInt8] {                                 // BAT
        [0x42, 0x41, 0x54,
         UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
         UInt8((size >> 8) & 0xff), UInt8(size & 0xff), key]
    }
}

// 293S 键位:主键 5×3 + 右侧 3 软键(下标 [row][col])
let keyIds: [[UInt8]] = [
    [0x0d, 0x0a, 0x07, 0x04, 0x01],
    [0x0e, 0x0b, 0x08, 0x05, 0x02],
    [0x0f, 0x0c, 0x09, 0x06, 0x03],
]
let softKeyIds: [UInt8] = [0x10, 0x11, 0x12]

var device: IOHIDDevice?
var packetSize = 1024
var leaderZero = false // 兼容回退:部分环境需要先补一个 0x00 报告头

func keyName(_ id: UInt8) -> String {
    for (r, row) in keyIds.enumerated() {
        if let c = row.firstIndex(of: id) { return "主键 r\(r + 1)c\(c + 1)" }
    }
    if let i = softKeyIds.firstIndex(of: id) { return "软键 \(i + 1)" }
    return String(format: "未知键 0x%02x", id)
}

// MARK: - HID 读写

@discardableResult
func write(_ payload: [UInt8]) -> Bool {
    guard let dev = device else { return false }
    var bytes = payload
    if leaderZero { bytes.insert(0x00, at: 0) }
    let kr = bytes.withUnsafeMutableBufferPointer { buf in
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x00, buf.baseAddress!, buf.count)
    }
    guard kr == kIOReturnSuccess else {
        FileHandle.standardError.write("write \(bytes.count)B 失败: 0x\(String(kr, radix: 16))\n".data(using: .utf8)!)
        return false
    }
    return true
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

func brightnessByte(percent: Int) -> UInt8 {
    let y = pow(Double(percent) / 100, 0.75) * 100
    return UInt8(max(0, min(100, y.rounded())))
}

// MARK: - 图像生成(100×100 JPEG,≤10KB)

func makeJPEG(_ text: String, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
    let side = 100
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.25))
    ctx.fill(CGRect(x: 8, y: 8, width: side - 16, height: side - 16))

    let font = CTFontCreateWithName((text.allSatisfy { $0.isASCII } ? "Helvetica-Bold" : "PingFang SC") as CFString, 32, nil)
    let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                  kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)]
    guard let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else { return nil }
    let line = CTLineCreateWithAttributedString(attrStr)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // 位图上下文 y 轴朝下,翻转文字
    ctx.textPosition = CGPoint(x: (CGFloat(side) - width) / 2, y: CGFloat(side - 58))
    CTLineDraw(line, ctx)

    guard let image = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

// MARK: - 设备发现

func findDevice(vid: Int, pid: Int) -> IOHIDDevice? {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match = [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid] as CFDictionary
    IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    CFRunLoopRunInMode(.defaultMode, 0.5, false) // 等枚举落地
    guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = set.first else {
        // 诊断:列出当前所有 HID 设备
        IOHIDManagerSetDeviceMatching(manager, nil)
        CFRunLoopRunInMode(.defaultMode, 0.5, false)
        if let all = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for d in all {
                let v = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? -1
                let p = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? -1
                let n = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
                FileHandle.standardError.write(String(format: "  HID: %@ 0x%04x:0x%04x\n", n, v, p).data(using: .utf8)!)
            }
        }
        return nil
    }
    return dev
}

// MARK: - 按键回调(C 函数指针,不可捕获局部变量)

let inputCallback: IOHIDReportCallback = { _, _, _, _, _, report, reportLength in
    let n = reportLength
    let hex = UnsafeBufferPointer(start: report, count: min(n, 16))
        .map { String(format: "%02x", $0) }.joined(separator: " ")
    guard n >= 11 else {
        print("📨 短报告(\(n)B): \(hex)")
        return
    }
    let bytes = UnsafeBufferPointer(start: report, count: n)
    let key = bytes[9], state = bytes[10]
    print("⌨️  \(keyName(key)) \(state == 0 ? "抬起" : "按下")   [\(hex)]")
}

// MARK: - 主流程

guard let dev = findDevice(vid: vendorId, pid: productId) else {
    FileHandle.standardError.write("未找到设备 0x\(String(vendorId, radix: 16)):0x\(String(productId, radix: 16)),请确认已插好\n".data(using: .utf8)!)
    exit(1)
}
device = dev

guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    FileHandle.standardError.write("IOHIDDeviceOpen 失败(设备可能被其他程序独占)\n".data(using: .utf8)!)
    exit(1)
}
print("✅ 已打开设备")

IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let inputLen = (IOHIDDeviceGetProperty(dev, "MaxInputReportSize" as CFString) as? Int) ?? 512
var inputBuffer = [UInt8](repeating: 0, count: inputLen)
inputBuffer.withUnsafeMutableBufferPointer { buf in
    IOHIDDeviceRegisterInputReportCallback(dev, buf.baseAddress!, buf.count, inputCallback, nil)
}

// 自动探测写入格式:packetSize × 是否补报告头
var opened = false
for mode in [(size: 1024, leader: false), (size: 1024, leader: true), (size: 512, leader: false), (size: 512, leader: true)] {
    packetSize = mode.size
    leaderZero = mode.leader
    if sendCmd(Cmd.heartbeat) { opened = true; print("✅ 握手成功:packetSize=\(packetSize) leaderZero=\(leaderZero)"); break }
}
guard opened else {
    FileHandle.standardError.write("握手失败:所有写入格式均被拒绝\n".data(using: .utf8)!)
    exit(1)
}

usleep(200_000)
sendCmd(Cmd.wake)
sendCmd(Cmd.brightness(brightnessByte(percent: 80)))
sendCmd(Cmd.clearPanel)
usleep(300_000)

let samples: [(UInt8, String, CGFloat, CGFloat, CGFloat)] = [
    (keyIds[0][4], "HI", 0.90, 0.25, 0.20),
    (keyIds[1][4], "293S", 0.15, 0.40, 0.90),
    (keyIds[2][4], "自主掌控", 0.10, 0.65, 0.35),
    (softKeyIds[2], "Z", 0.95, 0.70, 0.10),
]
for (key, text, r, g, b) in samples {
    guard let jpeg = makeJPEG(text, red: r, green: g, blue: b), jpeg.count <= maxKeyJPEGBytes else {
        print("⚠️ \(text) 生成 JPEG 失败"); continue
    }
    drawKey(key, jpeg: jpeg)
    print("🖼️  键 0x\(String(key, radix: 16)) 已写入 “\(text)”(\(jpeg.count)B JPEG)")
}

print("—— 监听按键 20 秒,请按压面板任意键 ——")
let heartbeatTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 7, 7, 0, 0) { _ in
    sendCmd(Cmd.heartbeat)
}
CFRunLoopAddTimer(CFRunLoopGetMain(), heartbeatTimer, .commonModes)
let stopTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 20, 0, 0, 0) { _ in
    CFRunLoopStop(CFRunLoopGetMain())
}
CFRunLoopAddTimer(CFRunLoopGetMain(), stopTimer, .commonModes)
CFRunLoopRun()

sendCmd(Cmd.close)
IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
print("👋 已断开")
