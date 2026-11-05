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
/// 统计项:可作 KeyAction 关联值随配置落盘(Codable 合成用 String rawValue)
enum StatKind: String, Codable, Hashable, CaseIterable, Sendable {
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

    deinit {
        // 进程级单例基本不会走到,但失败重试/测试场景会重复建实例:连接要还
        if connect != 0 { IOServiceClose(connect) }
    }

    /// 打开连接并枚举 Tp* 温度键(一次性;失败返回 false,槽位显示 N/A)
    func open() -> Bool {
        if connect != 0 { return !tpKeys.isEmpty }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            Self.log.notice("stats: AppleSMC 服务未找到")
            return false
        }
        defer { IOObjectRelease(service) } // 匹配引用必须归还,失败重试不再累积
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
    private struct State {
        var smc = SMCTemperatureReader()
        var prevTicks: host_cpu_load_info?
    }
    /// 采样可重叠(2s 定时器与 setSlots 触发各自起 Task):prevTicks 差分与 SMC open
    /// 是无同步裸读写的真数据竞争,锁内串行同时起到「在飞单飞」效果
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    func sample() -> StatSample {
        let gpu = Self.gpuUtilization() // 注册表查询无共享状态,不进锁
        return stateLock.withLock { state in
            StatSample(gpu: gpu, cpu: Self.cpuUtilization(previous: &state.prevTicks), temp: state.smc.hottestCPU())
        }
    }

    /// mach 系统调用:两次 host_statistics64 差分的非空闲占比
    /// 宿主 port 缓存:mach_host_self() 每次调用都会新建 send right,
    /// 2s 一采还不释放 = 稳定泄漏 port right;进程内宿主 port 恒定,取一次用到底
    private static let hostPort: mach_port_t = mach_host_self()

    static func cpuUtilization(previous: inout host_cpu_load_info?) -> Int? {
        var load = host_cpu_load_info()
        var size = mach_msg_type_number_t(4) // HOST_CPU_LOAD_INFO_COUNT(cpu_ticks 4 字段)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 4) { ptr in
                host_statistics(hostPort, 3 /*HOST_CPU_LOAD_INFO*/, ptr, &size)
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

/// 统计瓷贴渲染 v2(§6.33「暗夜仪表」):深底玻璃 + 270° 弧形仪表 + 白色大值带同色辉光
/// + 左上小标签;温度弧色随值绿→琥珀→红连续映射。fraction(0..1) 驱动弧进度,
/// sweepFrames 用旧→新 fraction 生成扫摆过渡帧(easeOutCubic)。文字 CoreText 直绘(实测)。
enum StatTileRenderer {
    /// 值 → 弧进度(gpu/cpu = 百分比/100;温度映射 35–90° 区间)
    static func fraction(kind: StatKind, celsiusOrPercent: Double) -> Double {
        switch kind {
        case .gpu, .cpu: return min(max(celsiusOrPercent / 100, 0), 1)
        case .temp: return min(max((celsiusOrPercent - 35) / (90 - 35), 0), 1)
        }
    }

    static func tile(kind: StatKind, value: String, fraction: Double) -> CGImage? {
        let side = StreamDock293S.keySize(column: 0)
        let s = CGFloat(side) / 112
        guard let ctx = DarkTileCanvas.beginCanvas(side: side) else { return nil }
        let celsius: Double? = kind == .temp ? Double(value.replacingOccurrences(of: "°", with: "")) : nil
        let accent = DarkTileStyle.accent(for: kind, tempCelsius: celsius)

        // 左上标签(左对齐,弱辉光)
        let labelRect = CGRect(x: 12 * s, y: CGFloat(side) - 32 * s, width: 60 * s, height: 18 * s)
        DarkTileCanvas.drawText(kind.label, size: 13 * s, weight: .semibold,
                                color: accent.copy(alpha: 0.9)!,
                                rect: labelRect,
                                ctx: ctx, align: .left)

        // 270° 弧:开口朝下,起点左下 -225°,终点右上 45°(顺时针 270°)
        let center = CGPoint(x: 56 * s, y: 52 * s)
        let radius = 31 * s
        let startAngle = Angle(-225), endAngle = Angle(45)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: DarkTileStyle.trackAlpha))
        ctx.setLineWidth(7 * s)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius,
                   startAngle: .pi * (startAngle.degrees / 180),
                   endAngle: .pi * (endAngle.degrees / 180), clockwise: false)
        ctx.strokePath()
        // 进度弧(辉光)
        let clamped = min(max(fraction, 0.001), 1)
        let sweep = (endAngle.degrees - startAngle.degrees) * clamped
        ctx.setStrokeColor(accent)
        ctx.setShadow(offset: .zero, blur: 6, color: accent)
        ctx.addArc(center: center, radius: radius,
                   startAngle: .pi * (startAngle.degrees / 180),
                   endAngle: .pi * ((startAngle.degrees + sweep) / 180), clockwise: false)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // 中央大值(白 + accent 辉光);字数多自动缩
        let valueSize: CGFloat = (value.count > 3 ? 21 : 26) * s
        DarkTileCanvas.drawText(value, size: valueSize, weight: .bold,
                                color: DarkTileStyle.valueWhite,
                                rect: CGRect(x: 0, y: center.y - 16 * s, width: CGFloat(side), height: 32 * s),
                                ctx: ctx)

        guard let upright = ctx.makeImage() else { return nil }
        return DarkTileCanvas.finishRotated(upright, side: side, space: ctx.colorSpace)
    }

    /// 旧签名兼容(占位帧/调色盘):fraction 未知按 0 画
    static func tile(kind: StatKind, value: String) -> CGImage? {
        tile(kind: kind, value: value, fraction: 0)
    }

    /// 数值变化扫摆帧:from→new easeOutCubic 6 帧(不含旧帧,首帧即 ~16% 进度处)
    static func sweepFrames(kind: StatKind, fromFraction: Double, toFraction: Double,
                            value: String) -> [CGImage] {
        let count = 6
        var frames: [CGImage] = []
        for step in 1...count {
            let p = easeOutCubic(Double(step) / Double(count))
            let fraction = fromFraction + (toFraction - fromFraction) * p
            if let image = tile(kind: kind, value: value, fraction: fraction) {
                frames.append(image)
            }
        }
        return frames
    }

    static func easeOutCubic(_ p: Double) -> Double {
        1 - pow(1 - min(max(p, 0), 1), 3)
    }
}

/// 角度小助手(弧计算可读性)
struct Angle {
    let degrees: Double
    init(_ degrees: Double) { self.degrees = degrees }
}
