import Foundation
import os

/// 虚拟设备传输:DeviceTransport 的无 HID 实现——「内存里的那块板子」。
/// 用途:无设备开发/UI 验证/演示(真机独占,调试实例与生产实例互斥时,
/// 虚拟设备让 UI 层的开发验证完全脱离硬件)。语义对齐 HIDTransport:
/// start → attach 事件 → 报文照收(丢弃) → stop。
///
/// 不做设备回放(按键模拟等)——那是 harness 的事;本类型只保证
/// DeviceController 全状态机在无硬件环境下可运行。
public final class VirtualTransport: @unchecked Sendable, DeviceTransport {
    public var onReport: (@Sendable ([UInt8]) -> Void)?
    public var onDeviceAttached: (@Sendable () -> Void)?
    public var onDeviceDetached: (@Sendable () -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var started = false
    /// 收到的完整报文头计数(诊断;命令按 sendCommand 边界计)
    private(set) public var commandCount = 0
    private(set) public var rawByteCount = 0

    private static let log = Logger(subsystem: "opendeck", category: "device")

    public init() {}

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        // 模拟热插拔:异步上报 attach,DeviceController 据此走校准路径
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.onLog?("虚拟设备:已连接(无硬件,报文丢弃)")
            self?.onDeviceAttached?()
        }
    }

    public func stop() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        started = false
        lock.unlock()
        onDeviceDetached?()
        onLog?("虚拟设备:已断开")
    }

    public func sendCommand(_ command: [UInt8]) {
        lock.lock()
        commandCount += 1
        lock.unlock()
    }

    public func sendRaw(_ bytes: [UInt8]) {
        lock.lock()
        rawByteCount += bytes.count
        lock.unlock()
    }

    public func setWriteTrace(_ trace: (@Sendable ([UInt8]) -> Void)?) {
        // 虚拟设备无字节流可追;诊断经 commandCount/rawByteCount 属性暴露
    }

    /// 便捷:报文统计快照(诊断/测试断言用)
    public func stats() -> (commands: Int, rawBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (commandCount, rawByteCount)
    }
}
