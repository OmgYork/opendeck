import AppKit
import CoreGraphics
import Foundation
import IOKit
import StreamDockKit
import os

// MARK: - Stats 集成采样(GPU / CPU 利用率 + 最热 CPU 温度)

/// 数据源(2026-10-18 本机实测):
/// - GPU 利用率:IOAccelerator 注册表 PerformanceStatistics["Device Utilization %"]
/// - CPU 利用率:mach host_statistics64 两次采样差分
/// - 温度:AppleSMC 现代接口——仅 selector 2 分发器(80 字节结构:data8@42=传统功能号,
///   data32@44=参数;keyInfo 因对齐 12 字节,整体 80 字节),Tp* 键为 4 字节 IEEE754 浮点温度
enum StatKind {
    case gpu
    case cpu
    case temp

    var label: String {
        switch self {
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        case .temp: return "CPU 温度"
        }
    }
}

struct StatSample {
    var gpu: Int?
    var cpu: Int?
    var temp: Double?
}

/// 现代 AppleSMC 连接与温度采样
/// nonisolated + @unchecked Sendable:采样在后台线程执行(IOKit 用户客户端线程安全,状态自守恒)
nonisolated final class SMCTemperatureReader: @unchecked Sendable {
    private static let log = Logger(subsystem: "opendeck", category: "stats")
    private var connect: io_connect_t = 0
    private var tpKeys: [String] = []

    struct Param {
        var d = Data(count: 80)
        init(funcID: UInt8? = nil, key: String? = nil, data32: UInt32 = 0, sizeAt28: UInt32? = nil) {
            if let key {
                var k = key.utf8.reduce(0 as UInt32) { $0 << 8 | UInt32($1) }
                withUnsafeBytes(of: &k) { d.replaceSubrange(0..<4, with: $0) }
            }
            if let funcID { d[42] = funcID }
            var v = data32.littleEndian
            withUnsafeBytes(of: &v) { d.replaceSubrange(44..<48, with: $0) }
            if let sizeAt28 {
                var s = sizeAt28.littleEndian
                withUnsafeBytes(of: &s) { d.replaceSubrange(28..<32, with: $0) }
            }
        }
        var key: String { String(d[0..<4].map { Character(UnicodeScalar($0)) }.reversed()).trimmingCharacters(in: .whitespaces) }
        var result: UInt8 { d[40] }
        var bytes: [UInt8] { Array(d[48..<80]) }
    }

    /// 打开连接并枚举 Tp* 温度键(一次性;失败返回 false,槽位显示 N/A)
    func open() -> Bool {
        if connect != 0 { return !tpKeys.isEmpty }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            Self.log.notice("stats: AppleSMC 服务未找到")
            return false
        }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connect)
        guard kr == KERN_SUCCESS, connect != 0 else {
            Self.log.notice("stats: IOServiceOpen kr=0x\(String(kr, radix: 16))")
            return false
        }
        let count = call(Param(funcID: 5, key: "#KEY", data32: 4, sizeAt28: 4))
        guard count.result == 0 else {
            Self.log.notice("stats: #KEY info result=\(count.result)")
            return false
        }
        var total = 0
        for b in count.bytes[0..<4] { total = total << 8 | Int(b) }
        var names: [String] = []
        for i in 0..<total {
            let r = call(Param(funcID: 8, data32: UInt32(i)))
            let n = r.key
            if n.count == 4 { names.append(n) }
        }
        self.tpKeys = names.filter { $0.hasPrefix("Tp") }
        Self.log.notice("stats: 枚举 \(total) 键,Tp 温度键 \(self.tpKeys.count) 个")
        return !self.tpKeys.isEmpty
    }

    /// Stats 分代 CPU 温度键表(exelban/stats Sensors/values.swift,group .CPU + average:true 的忠实拷贝)。
    /// 「Hottest CPU」只在精选键上取最大;全量 Tp* 会把表外传感器(如本机 Tp0g)算进来导致偏高
    private static func cpuTempKeys(forBrand brand: String) -> [String]? {
        if brand.contains("Apple M4") {
            return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        }
        if brand.contains("Apple M3") {
            return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                    "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        }
        if brand.contains("Apple M2") {
            return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        }
        if brand.contains("Apple M1") {
            return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X"]
        }
        return nil
    }

    private static func chipBrand() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 最热 CPU 温度:优先 Stats 精选键表(按芯片代际;与本机存在键取交集),无交集回退全部 Tp*
    func hottestCPU() -> Double? {
        guard open() else { return nil }
        var candidates = tpKeys
        if let curated = Self.cpuTempKeys(forBrand: Self.chipBrand()) {
            let matched = tpKeys.filter { curated.contains($0) }
            if !matched.isEmpty { candidates = matched }
        }
        var hottest: Double?
        var failures = 0
        for name in candidates {
            let r = call(Param(funcID: 5, key: name, data32: 4, sizeAt28: 4))
            guard r.result == 0, r.bytes.count >= 4 else {
                failures += 1
                continue
            }
            let f = r.bytes.prefix(4).withUnsafeBytes { $0.load(as: Float.self) }
            guard f.isFinite, f > 0, f < 150 else { continue }
            hottest = max(hottest ?? 0, Double(f))
        }
        if failures > 0 { Self.log.notice("stats: Tp 读取失败 \(failures)/\(candidates.count)") }
        return hottest
    }

    private func call(_ p: Param) -> Param {
        let input = p.d
        var output = Data(count: 80)
        var outSize = 80
        _ = input.withUnsafeBytes { ib in
            output.withUnsafeMutableBytes { ob in
                IOConnectCallStructMethod(connect, 2, ib.baseAddress, input.count, ob.baseAddress, &outSize)
            }
        }
        var r = Param()
        r.d = output
        return r
    }
}

/// 采样器:CPU / GPU / 温度(nonisolated:在后台 Task 中采样,避免阻塞主线程)
nonisolated final class StatSampler: @unchecked Sendable {
    private var smc = SMCTemperatureReader()
    private var prevTicks: host_cpu_load_info?

    func sample() -> StatSample {
        StatSample(gpu: Self.gpuUtilization(), cpu: Self.cpuUtilization(previous: &prevTicks), temp: smc.hottestCPU())
    }

    /// mach 系统调用:两次 host_statistics64 差分的非空闲占比
    static func cpuUtilization(previous: inout host_cpu_load_info?) -> Int? {
        var load = host_cpu_load_info()
        var size = mach_msg_type_number_t(4) // HOST_CPU_LOAD_INFO_COUNT(cpu_ticks 4 字段)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 4) { ptr in
                host_statistics(mach_host_self(), 3 /*HOST_CPU_LOAD_INFO*/, ptr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previous = load }
        guard let prev = previous else { return nil }
        // 与 Stats CPU readers 同口径:totalUsage = (user+sys)/total,nice 计入分母但不计入分子
        let userDelta = Int(load.cpu_ticks.0) - Int(prev.cpu_ticks.0)
        let sysDelta = Int(load.cpu_ticks.1) - Int(prev.cpu_ticks.1)
        let idleDelta = Int(load.cpu_ticks.2) - Int(prev.cpu_ticks.2)
        let niceDelta = Int(load.cpu_ticks.3) - Int(prev.cpu_ticks.3)
        let totalDelta = userDelta + sysDelta + idleDelta + niceDelta
        guard totalDelta > 0 else { return nil }
        return Int(Double(userDelta + sysDelta) / Double(totalDelta) * 100)
    }

    /// IOAccelerator 注册表:多 GPU 取最大利用率
    static func gpuUtilization() -> Int? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Int?
        while case let entry = IOIteratorNext(it), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let prop = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            else { continue }
            let util: Int?
            if let n = prop["Device Utilization %"] as? NSNumber {
                util = n.intValue
            } else if let s = prop["Device Utilization %"] as? String {
                util = Int(s)
            } else {
                util = nil
            }
            if let util { best = max(best ?? -1, util) }
        }
        return best
    }
}

/// 统计瓷贴渲染:112×112 深底 + 顶部标签 + 中央大值,末尾旋转 180°(设备方向;
/// UI 镜像侧 KeycapView 会转回正立,与设备帧同源)。
/// 文字用 CoreText 直绘(AppKit NSAttributedString.draw 在裸 CGContext 上坐标错乱,实测)
enum StatTileRenderer {
    static func tile(kind: StatKind, value: String) -> CGImage? {
        let side = StreamDock293S.keySize(column: 0)
        // 版式按 100→112 等比缩放,保持原设计比例
        let s = CGFloat(side) / 100
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let (bgTop, bgBottom, accent): (String, String, String) = {
            switch kind {
            case .gpu: return ("#81A1C1", "#5E81AC", "#ECEFF4")
            case .cpu: return ("#A3BE8C", "#8FBCBB", "#2E3440")
            case .temp: return ("#D08770", "#BF616A", "#2E3440")
            }
        }()
        // 深色底 + 顶部微提亮(与键帽拟真语言一致)
        ctx.setFillColor(HexCGColor.opaque(bgBottom) ?? CGColor(gray: 0.18, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(HexCGColor.opaque(bgTop)?.copy(alpha: 0.22) ?? CGColor(gray: 0.25, alpha: 0.2))
        ctx.fill(CGRect(x: 0, y: CGFloat(side) - 34 * s, width: CGFloat(side), height: 34 * s))

        let accentColor = HexCGColor.opaque(accent) ?? CGColor(gray: 1, alpha: 1)
        // 顶部标签
        let labelFont = CTFontCreateWithName(NSFont.systemFont(ofSize: 13 * s, weight: .semibold).fontName as CFString, 13 * s, nil)
        centered(NSAttributedString(string: kind.label, attributes: [
            .font: labelFont, .foregroundColor: accentColor,
        ]), in: CGRect(x: 0, y: CGFloat(side) - 30 * s, width: CGFloat(side), height: 26 * s), ctx: ctx)
        // 中央大值
        let valueFont = CTFontCreateWithName(NSFont.systemFont(ofSize: 30 * s, weight: .bold).fontName as CFString, (value.count > 3 ? 24 : 30) * s, nil)
        centered(NSAttributedString(string: value, attributes: [
            .font: valueFont, .foregroundColor: accentColor,
        ]), in: CGRect(x: 0, y: 18 * s, width: CGFloat(side), height: 52 * s), ctx: ctx)

        guard let upright = ctx.makeImage() else { return nil }
        // 设备 180° 显示:预旋转输出(UI 镜像侧 KeycapView 会转回正立)。
        // rotate 绕画布原点(左下角)旋转,必须先 translate 到对角再画,否则内容落到负坐标区只剩 1/4(实测)
        guard let rotated = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        rotated.translateBy(x: CGFloat(side), y: CGFloat(side))
        rotated.rotate(by: .pi)
        rotated.draw(upright, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        return rotated.makeImage()
    }

    /// CoreText 居中绘制(垂直以行光学中线对齐)
    private static func centered(_ text: NSAttributedString, in rect: CGRect, ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: rect.midX - CGFloat(width) / 2,
                                   y: rect.midY - bounds.midY + rect.origin.y)
        CTLineDraw(line, ctx)
    }

}
