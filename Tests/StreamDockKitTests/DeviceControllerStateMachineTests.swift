import CoreGraphics
import Foundation
import Testing

@testable import StreamDockKit

/// 记录型假传输:只把「什么时候发了什么」按序留下来,不碰 IOKit。
///
/// 与真 HIDTransport 的契约一致:回调可来自任意线程,写入保序。
private final class FakeTransport: @unchecked Sendable, DeviceTransport {
    private let lock = NSLock()
    private var _commands: [[UInt8]] = []
    private var _rawWrites: [[UInt8]] = []
    private var _startCount = 0
    private var _stopCount = 0

    var onReport: (@Sendable ([UInt8]) -> Void)?
    var onDeviceAttached: (@Sendable () -> Void)?
    var onDeviceDetached: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    var commands: [[UInt8]] { lock.withLock { _commands } }
    var rawWrites: [[UInt8]] { lock.withLock { _rawWrites } }
    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }

    func start() { lock.withLock { _startCount += 1 } }
    func stop() { lock.withLock { _stopCount += 1 } }
    func sendCommand(_ command: [UInt8]) { lock.withLock { _commands.append(command) } }
    func sendRaw(_ bytes: [UInt8]) { lock.withLock { _rawWrites.append(bytes) } }
    func setWriteTrace(_ trace: (@Sendable ([UInt8]) -> Void)?) {}

    // MARK: 测试驱动

    func attach() { onDeviceAttached?() }
    func detach() { onDeviceDetached?() }
    func report(_ bytes: [UInt8]) { onReport?(bytes) }

    /// 清空写入记录(只清记录,不动状态机)
    func resetWrites() {
        lock.withLock {
            _commands = []
            _rawWrites = []
        }
    }

    // MARK: 断言辅助

    /// 图像头(BAT 开头)携带的键 id,按发送顺序
    var imageKeyIds: [UInt8] {
        commands
            .filter { $0.starts(with: [0x42, 0x41, 0x54]) }
            .compactMap(\.last)
    }

    /// 全量重画一次 = 每键一个 STP 刷新命令
    var refreshCount: Int {
        commands.filter { $0 == StreamDock293S.refreshCommand }.count
    }

    /// 命令换算成可读标签,失败信息里直接看得出顺序错在哪
    func label(_ command: [UInt8]) -> String {
        switch command {
        case StreamDock293S.heartbeatCommand: return "握手"
        case StreamDock293S.wakeCommand: return "唤醒"
        case StreamDock293S.clearPanelCommand: return "清屏"
        case StreamDock293S.refreshCommand: return "刷新"
        default:
            if command.starts(with: [0x42, 0x41, 0x54]) { return "图像头" }
            if command.starts(with: [0x4c, 0x49, 0x47]) { return "亮度(\(command.last ?? 0))" }
            return "其它(\(command.count) 字节)"
        }
    }
}

/// DeviceController 状态机:校准序列、熄屏/唤醒/涂黑、断连重连。
/// 这些行为此前零测试——只有接上真设备才能验,于是长期处于「没人敢动」状态。
@Suite("DeviceController 状态机")
@MainActor
struct DeviceControllerStateMachineTests {

    /// 回调经 `Task { @MainActor }` 跳线程;断言前把主线程队列跑空
    private func settle() async {
        for _ in 0..<64 { await Task.yield() }
    }

    private func makeKeyImage() -> CGImage? {
        let side = StreamDock293S.keySize(column: 0)
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private var allKeyIds: [UInt8] {
        (0..<StreamDock293S.rows).flatMap { row in
            (0..<StreamDock293S.columns).compactMap { StreamDock293S.keyId(row: row, column: $0) }
        }
    }

    // MARK: - 校准

    @Test("连接校准:握手→亮度→清屏→全量重画(顺序即契约)")
    func calibrateSequence() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        #expect(fake.startCount == 1)

        fake.attach()
        await settle()

        #expect(controller.state == .running)
        // 握手必须最先:自重启过的设备在见到 CONNECT 前静默丢弃一切屏幕命令
        let expected: [[UInt8]] = [
            StreamDock293S.heartbeatCommand,
            StreamDock293S.wakeCommand,
            StreamDock293S.brightnessCommand(StreamDock293S.brightnessByte(percent: 80)),
            StreamDock293S.clearPanelCommand,
            StreamDock293S.wakeCommand, // redrawAll 的唤醒
        ]
        #expect(
            fake.commands == expected,
            "实际序列: \(fake.commands.map(fake.label))"
        )
        // 缓存为空时不该有图像下发
        #expect(fake.imageKeyIds.isEmpty)
    }

    @Test("连接校准按已设亮度下发,不是默认值")
    func calibrateUsesConfiguredBrightness() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        controller.setBrightness(35)
        fake.resetWrites()

        fake.attach()
        await settle()

        #expect(fake.commands.contains(
            StreamDock293S.brightnessCommand(StreamDock293S.brightnessByte(percent: 35))
        ))
        #expect(controller.brightnessPercent == 35)
    }

    // MARK: - 熄屏

    @Test("熄屏:背光归零 + 15 键涂黑,心跳保持(不 stop 传输)")
    func screenOffBlacksOutWithoutStopping() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        fake.resetWrites()

        controller.screenOff()

        #expect(controller.isScreenOff)
        #expect(controller.keysBlacked)
        // 15 键先各画一帧黑图 + 各一次刷新,背光归零排在最后:
        // 反过来会留下「最暗档但仍亮着」的中间态(设备背光 0 不是黑屏,只是最暗)
        #expect(fake.imageKeyIds == allKeyIds, "实际键序: \(fake.imageKeyIds)")
        #expect(fake.refreshCount == 15)
        #expect(
            fake.commands.last == StreamDock293S.brightnessCommand(StreamDock293S.brightnessByte(percent: 0)),
            "末条命令应是亮度 0: \(fake.commands.map(fake.label))"
        )
        // 旧机制「暂停心跳→固件自重启待机」已废弃:熄屏期间输入必须仍然可达
        #expect(fake.stopCount == 0)
        // 背光属性不被熄屏改写(唤醒要恢复它)
        #expect(controller.brightnessPercent == 80)
    }

    @Test("熄屏幂等:重复调用不再下发")
    func screenOffIsIdempotent() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        controller.screenOff()
        fake.resetWrites()

        controller.screenOff()

        #expect(fake.commands.isEmpty, "重复熄屏应被守卫拦下: \(fake.commands.map(fake.label))")
    }

    @Test("唤醒:恢复原亮度并按缓存重画,两个标志同时复位")
    func wakeRestoresBrightnessAndCache() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        guard let image = makeKeyImage() else {
            Issue.record("测试位图创建失败")
            return
        }
        // 熄屏前先在两格有内容
        controller.drawKey(row: 0, column: 0, image: image)
        controller.drawKey(row: 2, column: 4, image: image)
        controller.screenOff()
        fake.resetWrites()

        controller.wakeFromScreenOff()
        await settle()

        #expect(!controller.isScreenOff)
        #expect(!controller.keysBlacked)
        #expect(
            fake.commands.first == StreamDock293S.brightnessCommand(StreamDock293S.brightnessByte(percent: 80)),
            "唤醒应先恢复背光: \(fake.commands.map(fake.label))"
        )
        // 唤醒重画只画缓存里那两格(不是全 15 格)
        let expectedIds = [
            StreamDock293S.keyId(row: 0, column: 0),
            StreamDock293S.keyId(row: 2, column: 4),
        ].compactMap { $0 }
        #expect(fake.imageKeyIds == expectedIds, "实际: \(fake.imageKeyIds)")
        #expect(fake.refreshCount == expectedIds.count)
    }

    @Test("未熄屏时唤醒是空操作")
    func wakeWithoutScreenOffDoesNothing() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        fake.resetWrites()

        controller.wakeFromScreenOff()

        #expect(fake.commands.isEmpty)
    }

    // MARK: - 键面涂黑(与熄屏共用同一套键面状态)

    @Test("涂黑幂等,恢复时按缓存重画")
    func keysBlackedIsIdempotent() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        guard let image = makeKeyImage() else {
            Issue.record("测试位图创建失败")
            return
        }
        controller.drawKey(row: 1, column: 2, image: image)
        fake.resetWrites()

        controller.setKeysBlacked(true)
        #expect(fake.refreshCount == 15)
        fake.resetWrites()

        controller.setKeysBlacked(true) // 同值:no-op
        #expect(fake.commands.isEmpty, "同值涂黑不应重发: \(fake.commands.map(fake.label))")

        controller.setKeysBlacked(false)
        let expectedId = StreamDock293S.keyId(row: 1, column: 2)
        #expect(fake.imageKeyIds == [expectedId].compactMap { $0 })
        #expect(!controller.keysBlacked)
    }

    @Test("熄灭态下画键只进缓存,不上屏(防插件/编辑盖掉黑屏)")
    func drawKeyDuringScreenOffOnlyCaches() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        controller.screenOff()
        fake.resetWrites()
        guard let image = makeKeyImage() else {
            Issue.record("测试位图创建失败")
            return
        }

        controller.drawKey(row: 0, column: 1, image: image)
        #expect(fake.commands.isEmpty, "熄屏中不应写设备: \(fake.commands.map(fake.label))")

        // 唤醒后这帧必须补上
        controller.wakeFromScreenOff()
        await settle()
        let expectedId = StreamDock293S.keyId(row: 0, column: 1)
        #expect(fake.imageKeyIds == [expectedId].compactMap { $0 })
    }

    @Test("熄屏期间的涂黑解除只记账不写屏,唤醒时统一重画")
    func keysBlackedDuringScreenOffDefersToWake() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        guard let image = makeKeyImage() else {
            Issue.record("测试位图创建失败")
            return
        }
        controller.drawKey(row: 1, column: 3, image: image)
        controller.screenOff()
        fake.resetWrites()

        // 场景:熄屏期间内屏亮度回升,BrightnessCoordinator 解除涂黑。
        // 旧行为在熄屏态发整套重画(背光归零下无意义);现在只解除记账
        controller.setKeysBlacked(false)
        #expect(!controller.keysBlacked, "记账应解除")
        #expect(fake.commands.isEmpty, "熄屏中不应写设备: \(fake.commands.map(fake.label))")

        // 唤醒必须重画:记账已是 false,不能依赖「记账差异」触发——否则键面停在黑帧
        controller.wakeFromScreenOff()
        await settle()
        #expect(!controller.isScreenOff)
        let expectedId = StreamDock293S.keyId(row: 1, column: 3)
        #expect(fake.imageKeyIds == [expectedId].compactMap { $0 }, "唤醒后应按缓存重画: \(fake.imageKeyIds)")
    }

    // MARK: - 断连重连

    @Test("断连重连:重新校准并按缓存全量重画")
    func reattachRedrawsCache() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        guard let image = makeKeyImage() else {
            Issue.record("测试位图创建失败")
            return
        }
        controller.drawKey(row: 1, column: 3, image: image)
        let expectedId = StreamDock293S.keyId(row: 1, column: 3)

        fake.detach()
        await settle()
        #expect(controller.state == .disconnected)
        fake.resetWrites()

        fake.attach()
        await settle()
        #expect(controller.state == .running)
        // 校准序列照旧
        #expect(fake.commands.first == StreamDock293S.heartbeatCommand)
        // 缓存那格在最末一轮重画里出现
        #expect(fake.imageKeyIds == [expectedId].compactMap { $0 })
    }

    @Test("断开不清理缓存:重插后仍能恢复键面")
    func detachKeepsCache() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        guard let image = makeKeyImage() else {
            Issue.record("测试位图创建失败")
            return
        }
        controller.drawKey(row: 2, column: 0, image: image)
        fake.detach()
        await settle()
        fake.resetWrites()

        fake.attach()
        await settle()

        let expectedId = StreamDock293S.keyId(row: 2, column: 0)
        #expect(fake.imageKeyIds == [expectedId].compactMap { $0 })
    }

    // MARK: - 输入报告

    @Test("输入报告解析后上抛为 KeyEvent")
    func reportBecomesKeyEvent() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        var events: [(row: Int, column: Int, phase: KeyEvent.Phase)] = []
        controller.onKeyEvent = { event in
            events.append((event.row, event.column, event.phase))
        }
        controller.start()
        fake.attach()
        await settle()

        // 输入键位空间:0x02 = 物理顶行第二颗
        var report = [UInt8](repeating: 0, count: 11)
        report[9] = 0x02
        report[10] = 1
        fake.report(report)
        await settle()

        #expect(events.count == 1)
        #expect(events.first?.row == 0)
        #expect(events.first?.column == 1)
        #expect(events.first?.phase == .down)
    }

    @Test("停机:发断开命令后停传输并置为未连接")
    func shutdownSendsCloseAndStops() async {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle()
        fake.resetWrites()

        controller.shutdown()

        #expect(fake.commands.first == StreamDock293S.closeCommand)
        #expect(fake.stopCount == 1)
        #expect(controller.state == .disconnected)
    }
}
