import CoreGraphics
import Foundation
import Observation

/// 面板控制器:面向 UI 的唯一入口。
/// 状态机:断开 →(热插拔发现)→ 连接校准(唤醒/亮度/清屏/全量重画)→ 运行(心跳+按键)→(拔线)→ 断开。
@MainActor
@Observable
public final class DeviceController {
    public private(set) var state: ConnectionState = .disconnected
    public private(set) var brightnessPercent: Int = 80
    /// 熄屏待机中(心跳已暂停,设备将自重启黑屏;任意按键唤醒)
    public private(set) var isScreenOff = false

    /// 按键事件回调(主线程)
    public var onKeyEvent: ((KeyEvent) -> Void)?
    /// 诊断日志(主线程)
    public var onLog: ((String) -> Void)?

    private let transport = HIDTransport()
    /// 已画键位缓存:index = row * columns + column;设备休眠唤醒/重插后据此全量重画
    private var keyImageCache: [Int: CGImage] = [:]

    public init() {
        transport.onReport = { [weak self] bytes in
            guard let self else { return }
            if let event = StreamDock293S.parseKeyEvent(fromReport: bytes) {
                Task { @MainActor in
                    self.onKeyEvent?(event)
                }
            } else if bytes.contains(where: { $0 != 0 }) {
                let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                Task { @MainActor in
                    self.onLog?("未识别输入报告: \(hex)")
                }
            }
        }
        transport.onDeviceAttached = { [weak self] in
            Task { @MainActor in self?.handleAttached() }
        }
        transport.onDeviceDetached = { [weak self] in
            Task { @MainActor in self?.handleDetached() }
        }
        transport.onLog = { [weak self] message in
            Task { @MainActor in self?.onLog?(message) }
        }
    }

    // MARK: - 生命周期

    /// 开始热插拔监控;发现已知设备自动连接并校准
    public func start() {
        transport.start()
        onLog?("开始监控热插拔(VID 0x6603 等 293S 系列)")
    }

    /// 发送断开命令并停止监控(应用退出时调用)
    public func shutdown() {
        transport.sendCommand(StreamDock293S.closeCommand)
        transport.stop()
        state = .disconnected
    }

    // MARK: - 控制

    public func setBrightness(_ percent: Int) {
        let clamped = max(0, min(100, percent))
        brightnessPercent = clamped
        transport.sendCommand(StreamDock293S.brightnessCommand(StreamDock293S.brightnessByte(percent: clamped)))
    }

    public func clearAll() {
        transport.sendCommand(StreamDock293S.clearPanelCommand)
    }

    // MARK: - 熄屏/唤醒

    /// 熄屏:清屏 + 暂停心跳 → 设备 ≤8s 自重启进入黑屏待机。
    /// 键面缓存保留,唤醒时全量重画。
    public func screenOff() {
        guard state == .running, !isScreenOff else { return }
        isScreenOff = true
        transport.sendCommand(StreamDock293S.clearPanelCommand)
        transport.suspendHeartbeat()
        onLog?("熄屏:心跳已暂停,设备进入待机(按任意键唤醒)")
    }

    /// 从熄屏唤醒:恢复心跳 + 完整校准(CONNECT→DIS→亮度→清屏→重画)
    public func wakeFromScreenOff() {
        guard isScreenOff else { return }
        isScreenOff = false
        transport.resumeHeartbeat()
        calibrate()
        onLog?("已从熄屏唤醒,校准完成")
    }

    /// 画一个键:渲染责任在调用方(IconRenderer),此处负责 JPEG 编码+协议下发+缓存
    public func drawKey(row: Int, column: Int, image: CGImage) {
        guard StreamDock293S.rowIds(indicesValid: row, column),
              let keyId = StreamDock293S.keyId(row: row, column: column)
        else { return }

        keyImageCache[row * StreamDock293S.columns + column] = image
        guard state == .running else { return }

        guard let jpeg = IconRenderer.jpeg(from: image) else {
            onLog?("JPEG 编码失败 r\(row)c\(column)")
            return
        }
        transport.sendCommand(StreamDock293S.imageHeaderCommand(jpegSize: jpeg.count, keyId: keyId))
        for chunk in StreamDock293S.imageChunks(jpeg) {
            transport.sendRaw(chunk)
        }
        transport.sendCommand(StreamDock293S.refreshCommand)
    }

    /// 诊断:追踪每个实际写入的报文(harness 与参考实现的字节流 diff 用)
    public func enableWriteTrace(_ trace: @escaping @Sendable ([UInt8]) -> Void) {
        transport.onWrite = trace
    }

    /// 唤醒屏幕并按缓存全量重画(设备自行休眠/重插后的恢复手段)
    public func redrawAll() {
        transport.sendCommand(StreamDock293S.wakeCommand)
        for index in keyImageCache.keys.sorted() {
            let row = index / StreamDock293S.columns
            let column = index % StreamDock293S.columns
            guard let image = keyImageCache[index],
                  let keyId = StreamDock293S.keyId(row: row, column: column),
                  let jpeg = IconRenderer.jpeg(from: image)
            else { continue }
            transport.sendCommand(StreamDock293S.imageHeaderCommand(jpegSize: jpeg.count, keyId: keyId))
            for chunk in StreamDock293S.imageChunks(jpeg) {
                transport.sendRaw(chunk)
            }
            transport.sendCommand(StreamDock293S.refreshCommand)
        }
    }

    // MARK: - 私有

    private func handleAttached() {
        state = .running
        onLog?("设备已连接,执行校准")
        calibrate()
    }

    /// 校准序列:握手必须最先(自重启过的设备在见到 CONNECT 前静默丢弃一切屏幕命令,实测 2026-10-13)
    private func calibrate() {
        transport.sendCommand(StreamDock293S.heartbeatCommand)
        transport.sendCommand(StreamDock293S.wakeCommand)
        setBrightness(brightnessPercent)
        clearAll()
        redrawAll()
    }

    private func handleDetached() {
        state = .disconnected
        onLog?("设备已断开,等待重新插入")
    }
}
