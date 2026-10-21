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
    /// 键面纯黑覆盖中(熄屏 / 亮度跟随的 0% 态共用;公开只读供 app 层判断按键点亮)
    public private(set) var keysBlacked = false

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
        onLog?("亮度 → \(clamped)%")
    }

    public func clearAll() {
        transport.sendCommand(StreamDock293S.clearPanelCommand)
    }

    // MARK: - 熄屏/唤醒

    /// 熄屏:全键画纯黑 + 背光归零。心跳保持——设备始终被认领、输入随时可达、唤醒即时。
    /// (旧机制「暂停心跳→固件自重启待机」已废弃:无主待机态输入可能死透、app 全盲,
    ///  酿成「唤醒→按键→又熄屏」死循环,2026-10-14 日志实证;CLE 全清亦被固件静默忽略)
    public func screenOff() {
        guard state == .running, !isScreenOff else { return }
        isScreenOff = true
        setKeysBlacked(true)
        transport.sendCommand(StreamDock293S.brightnessCommand(StreamDock293S.brightnessByte(percent: 0)))
        onLog?("熄屏:键面已黑、背光归零(心跳保持,按任意键即时唤醒)")
    }

    /// 从熄屏唤醒:恢复背光 + 按缓存全量重画(心跳本就存活,无需重握手)
    public func wakeFromScreenOff() {
        guard isScreenOff else { return }
        isScreenOff = false
        setBrightness(brightnessPercent)
        setKeysBlacked(false)
        onLog?("已从熄屏唤醒,键面已恢复")
    }

    /// Mac 系统睡眠唤醒后的主动恢复:睡眠期间心跳中断,设备多半已自重启进待机,
    /// 且 USB 未必重新枚举(不枚举则 attach 校准路径不会触发)。握手先行 + 按缓存
    /// 全量重画,状态标志复位(与 handleAttached 同语义,但不重开传输);
    /// 若设备确实重枚举了,本方法在 .running 守卫下让位给 attach 路径
    public func recalibrateAfterSystemWake() {
        guard state == .running else { return }
        isScreenOff = false
        keysBlacked = false
        onLog?("系统唤醒:重新校准(握手→亮度→清屏→按缓存全量重画)")
        calibrate()
    }

    /// 键面纯黑覆盖/恢复:熄屏与「亮度跟随 0%」共用。只涂黑可见内容,
    /// 不触碰状态机与 keyImageCache;恢复 = 按缓存全量重画
    public func setKeysBlacked(_ black: Bool) {
        guard keysBlacked != black, state == .running else { return }
        keysBlacked = black
        if black {
            blackoutKeys()
        } else {
            redrawAll()
        }
    }

    /// 全键下发纯黑键面(不触碰 keyImageCache——唤醒时据此恢复真实键面)
    private func blackoutKeys() {
        guard let black = Self.blackImage(),
              let jpeg = IconRenderer.jpeg(from: black) else {
            onLog?("熄屏失败:黑图 JPEG 编码失败")
            return
        }
        for row in 0..<StreamDock293S.rows {
            for column in 0..<StreamDock293S.columns {
                guard let keyId = StreamDock293S.keyId(row: row, column: column) else { continue }
                transport.sendCommand(StreamDock293S.imageHeaderCommand(jpegSize: jpeg.count, keyId: keyId))
                for chunk in StreamDock293S.imageChunks(jpeg) {
                    transport.sendRaw(chunk)
                }
                transport.sendCommand(StreamDock293S.refreshCommand)
            }
        }
    }

    /// 112×112 纯黑位图(键面原生尺寸)
    private static func blackImage() -> CGImage? {
        let side = StreamDock293S.keySize(column: 0)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// 画一个键:渲染责任在调用方(IconRenderer),此处负责 JPEG 编码+协议下发+缓存
    public func drawKey(row: Int, column: Int, image: CGImage) {
        guard StreamDock293S.rowIds(indicesValid: row, column),
              let keyId = StreamDock293S.keyId(row: row, column: column)
        else { return }

        // 缓存原始帧:熄屏/断开时也要更新,恢复时重发
        keyImageCache[row * StreamDock293S.columns + column] = image
        guard state == .running else { return }

        // 熄屏/键面纯黑中只更新缓存、不写设备:防插件 setImage/编辑操作盖掉黑屏;恢复时 redrawAll
        guard !isScreenOff, !keysBlacked else { return }

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
        sendCachedFrames()
    }

    /// 按缓存全量重发(不唤醒)
    private func sendCachedFrames() {
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
        isScreenOff = false // 熄屏中拔插视同唤醒:校准序列本身即恢复键面与背光
        keysBlacked = false
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
