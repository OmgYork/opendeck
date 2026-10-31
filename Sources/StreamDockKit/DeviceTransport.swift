import Foundation

/// 设备传输接缝:DeviceController 状态机只依赖这层,不认识 IOKit。
///
/// 存在的理由是可测性:校准序列、熄屏/唤醒/涂黑互斥、断连重绘这些行为只跟「什么时候
/// 发了什么命令」有关,与真实 HID 无关。真实现见 `HIDTransport`;测试用记录型假实现
/// 直接驱动状态机(见 Tests/StreamDockKitTests/DeviceControllerStateMachineTests.swift)。
///
/// 线程契约(与 HIDTransport 既有行为一致,不要收紧):
/// - 生命周期与回调可能在任意线程发生,`onReport` / `onDeviceAttached` / `onDeviceDetached`
///   / `onLog` 由实现方在其原生线程触发,接收方自行跳线程(DeviceController 内部跳 MainActor)。
/// - `sendCommand` / `sendRaw` 必须保序(旧平台要求命令串行),不得重排。
public protocol DeviceTransport: AnyObject, Sendable {
    /// 设备输入报告(原始字节,解析是上层的事)
    var onReport: (@Sendable ([UInt8]) -> Void)? { get set }
    /// 已知设备接入(已完成打开与输入回调注册)
    var onDeviceAttached: (@Sendable () -> Void)? { get set }
    /// 当前设备移除
    var onDeviceDetached: (@Sendable () -> Void)? { get set }
    /// 传输层诊断日志
    var onLog: (@Sendable (String) -> Void)? { get set }

    /// 开始热插拔监控(幂等)
    func start()
    /// 停止监控并释放设备(幂等;务必在进程退出前调用)
    func stop()
    /// 发送一条协议命令(实现方负责封包)
    func sendCommand(_ command: [UInt8])
    /// 发送原始字节块(图像数据,实现方不封包)
    func sendRaw(_ bytes: [UInt8])
    /// 写入追踪(诊断用,任意时刻调用安全)
    func setWriteTrace(_ trace: (@Sendable ([UInt8]) -> Void)?)
}
