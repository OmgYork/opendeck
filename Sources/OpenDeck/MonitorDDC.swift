import Darwin
import Foundation
import IOKit

// MARK: - DDC/CI 传输层（Apple Silicon IOAVService）
//
// 与 m1ddc / MonitorControl 同一套私有 API：IOAVServiceCreateWithService +
// IOAVServiceRead/WriteI2C。帧格式（MCCS over DDC/CI）：
//   读: 6E 82 01 <vcp> <cksum>        → 12 字节回复 6E .. 02 <rc> <vcp> <type> <maxHiLo> <curHiLo> <cksum>
//   写: 6E 84 03 <vcp> <hi> <lo> <cksum>
//   cksum = 0x6E ^ 寻址字节 ^ 其余字节异或
// 0xF4（LG 输入源）走备用寻址 0x50，其余走 0x51。

@_silgen_name("IOAVServiceCreate")
private func IOAVServiceCreate(_ allocator: CFAllocator?) -> CFTypeRef?

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> CFTypeRef?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(
    _ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
    _ buffer: UnsafeMutableRawPointer, _ size: UInt32
) -> kern_return_t

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(
    _ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
    _ buffer: UnsafeMutableRawPointer, _ size: UInt32
) -> kern_return_t

/// 一次动作的执行结果（供日志与键面反馈）
enum MonitorOutcome: Sendable {
    case ok(String)
    case failed(String)
}

enum MonitorDDC {
    /// DDC 芯片地址（I2C 七位地址 << 1，m1ddc 同值）
    private static let chipAddress: UInt32 = 0x37
    /// 默认寻址字节 / LG 0xF4 备用寻址字节
    private static let addrDefault: UInt8 = 0x51
    private static let addrAlternate: UInt8 = 0x50
    private static let ddcWaitMicros: UInt32 = 10_000
    /// 输入源状态文件（与 ~/bin/lg-toggle.sh 共用，保证两条路径不打架）
    static let inputStatePath = NSString(string: "~/.cache/lg_input").expandingTildeInPath

    // MARK: 对外

    /// 执行一条语义动作：读当前值 → 算目标值 → 写 → 读回校验
    static func apply(_ command: MonitorCommand) -> MonitorOutcome {
        let spec = command.spec
        do {
            switch spec.op {
            case .switchInput(let mac, let pc):
                let target: Int
                switch command {
                case .inputMac: target = mac
                case .inputPC: target = pc
                default: target = currentInputIsMac() ? pc : mac
                }
                try write(code: spec.code, value: target)
                recordInput(isMac: target == mac)
                return .ok("\(command.title) ✓")

            case .set(let value):
                try write(code: spec.code, value: value)
                if spec.disruptive {
                    // 链路重协商期间读不回来是预期行为，不做校验、不重试
                    return .ok("\(command.title)（画面会闪断十余秒）")
                }
                let after = (try? read(code: spec.code))?.current ?? value
                return .ok("\(command.title) → \(after)")

            case .step(let delta):
                let reading = try read(code: spec.code)
                let target = min(max(reading.current + delta, 0), max(reading.maximum, 0))
                try write(code: spec.code, value: target)
                let after = (try? read(code: spec.code))?.current ?? target
                return .ok("\(command.title) → \(after)")

            case .manualTempStep(let delta):
                // 0x69 只在「手动」档可写：先确保处于手动色温档（0x14 = 65502）
                let preset = try read(code: 0x14)
                if preset.current != 65502 {
                    try write(code: 0x14, value: 65502)
                }
                let reading = try read(code: 0x69)
                let ladder = MonitorCommand.manualTempLadder
                guard let nearest = ladder.enumerated().min(by: {
                    abs($0.element - reading.current) < abs($1.element - reading.current)
                })?.offset else {
                    return .failed("\(command.title): 刻度表为空")
                }
                let target = ladder[min(max(nearest + delta, 0), ladder.count - 1)]
                try write(code: 0x69, value: target)
                let after = (try? read(code: 0x69))?.current ?? target
                return .ok("\(command.title) → \(after)K")
            }
        } catch let error as MonitorDDCError {
            return .failed("\(command.title): \(error.description)")
        } catch {
            return .failed("\(command.title): \(error.localizedDescription)")
        }
    }

    /// 只读当前值（托盘/键面显示用）
    static func currentValue(of command: MonitorCommand) -> Int? {
        try? read(code: command.spec.code).current
    }

    /// 当前输入源（nil = 状态文件缺失/未知）
    static func currentInputIsMac() -> Bool {
        guard let text = try? String(contentsOfFile: inputStatePath, encoding: .utf8) else { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "mac"
    }

    // MARK: DDC 原语

    static func read(code: UInt8) throws -> (current: Int, maximum: Int) {
        let service = try openExternalService()
        let addr = address(for: code)
        var request: [UInt8] = [0x82, 0x01, code, 0]
        // 读帧校验 NOT 含寻址字节（m1ddc prepareDDCRead 同款；含进去会被显示器判为坏帧）
        request[3] = 0x6E ^ request[0] ^ request[1] ^ request[2]

        // 写命令之后显示器可能还压着上一帧回复，读到错位数据是常态：
        // 逐次校验帧、失败就等一拍重发，最多 3 次（m1ddc 用固定双写，这里用校验重试更稳）
        var lastReply: [UInt8] = []
        for attempt in 0..<3 {
            // 关键：这台显示器的 DDC 请求必须连写两帧才会应答（m1ddc 的 DDC_ITERATIONS=2），
            // 只写一帧时 IOKit 返回 0 但拿回来的是无效应答
            for _ in 0..<2 {
                usleep(ddcWaitMicros)
                var writeBuffer = request
                let writeResult = IOAVServiceWriteI2C(service, chipAddress, UInt32(addr), &writeBuffer, 4)
                guard writeResult == 0 else { throw MonitorDDCError.io(writeResult) }
            }

            usleep(ddcWaitMicros + UInt32(attempt) * 20_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let readResult = IOAVServiceReadI2C(service, chipAddress, UInt32(addr), &reply, 12)
            guard readResult == 0 else { throw MonitorDDCError.io(readResult) }
            lastReply = reply
            // 帧校验：不验就会把错位数据当值
            guard reply[0] == 0x6E, reply[2] == 0x02, reply[4] == code else { continue }
            guard reply[3] == 0 else { throw MonitorDDCError.unsupported(code, reply[3]) }
            let maximum = Int(reply[6]) << 8 | Int(reply[7])
            let current = Int(reply[8]) << 8 | Int(reply[9])
            return (current, maximum)
        }
        throw MonitorDDCError.badReply(
            lastReply.count > 0 ? lastReply[0] : 0,
            lastReply.count > 2 ? lastReply[2] : 0,
            lastReply.count > 4 ? lastReply[4] : 0
        )
    }

    /// 调试用：发一次读请求并原样返回 12 字节回复（不做帧校验）
    static func rawRead(code: UInt8) -> [UInt8] {
        guard let service = try? openExternalService() else { return [] }
        let addr = address(for: code)
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = 0x6E ^ request[0] ^ request[1] ^ request[2]
        usleep(ddcWaitMicros)
        var writeBuffer = request
        _ = IOAVServiceWriteI2C(service, chipAddress, UInt32(addr), &writeBuffer, 4)
        usleep(ddcWaitMicros)
        var reply = [UInt8](repeating: 0, count: 12)
        _ = IOAVServiceReadI2C(service, chipAddress, UInt32(addr), &reply, 12)
        return reply
    }

    static func write(code: UInt8, value: Int) throws {
        let service = try openExternalService()
        let addr = address(for: code)
        var frame: [UInt8] = [
            0x84, 0x03, code,
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0,
        ]
        frame[5] = 0x6E ^ addr ^ frame[0] ^ frame[1] ^ frame[2] ^ frame[3] ^ frame[4]
        // 与 m1ddc 一致：固定写两帧（首帧会被丢弃，只写一次等于没写）
        var lastError: kern_return_t = 0
        for _ in 0..<2 {
            usleep(ddcWaitMicros)
            var buffer = frame
            lastError = IOAVServiceWriteI2C(service, chipAddress, UInt32(addr), &buffer, 6)
        }
        guard lastError == 0 else { throw MonitorDDCError.io(lastError) }
        // 写后让显示器把 ACK 吐完，避免下一次读拿到上一帧的尾巴
        usleep(60_000)
    }

    // MARK: 私有

    private static func address(for code: UInt8) -> UInt8 {
        code == 0xF4 ? addrAlternate : addrDefault
    }

    private static func recordInput(isMac: Bool) {
        let path = inputStatePath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? (isMac ? "mac\n" : "pc\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 取外部显示器（Location=External）的 AVService
    private static func openExternalService() throws -> CFTypeRef {
        // 先用默认构造器（m1ddc 主路径：主显示器所在的 AVService），拿不到再按
        // DCPAVServiceProxy / Location=External 逐个匹配
        if let service = IOAVServiceCreate(kCFAllocatorDefault) {
            return service
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else {
            throw MonitorDDCError.noExternalDisplay
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
            guard location == "External" else { continue }
            if let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) {
                return service
            }
        }
        throw MonitorDDCError.noExternalDisplay
    }
}

enum MonitorDDCError: Error {
    case noExternalDisplay
    case io(kern_return_t)
    case badReply(UInt8, UInt8, UInt8)
    case unsupported(UInt8, UInt8)

    var description: String {
        switch self {
        case .noExternalDisplay: "未找到外接显示器（检查 USB-C/DP 连接）"
        case .io(let code): "I2C 通信失败（0x\(String(code, radix: 16))）"
        case .badReply(let head, let op, let vcp):
            "回复帧异常（head=0x\(String(head, radix: 16)) op=0x\(String(op, radix: 16)) vcp=0x\(String(vcp, radix: 16))）"
        case .unsupported(let vcp, let status):
            "显示器不支持 0x\(String(vcp, radix: 16))（rc=\(status)）"
        }
    }
}
