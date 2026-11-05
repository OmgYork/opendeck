import CoreGraphics
import Foundation
import StreamDockKit
import Testing

@testable import OpenDeck

/// 记录型假传输(与 StreamDockKitTests 同构;跨测试 target 无法共享,故此处复制最小版)。
private final class FakeTransport: @unchecked Sendable, DeviceTransport {
    private let lock = NSLock()
    private var _commands: [[UInt8]] = []
    private var _startCount = 0

    var onReport: (@Sendable ([UInt8]) -> Void)?
    var onDeviceAttached: (@Sendable () -> Void)?
    var onDeviceDetached: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    var commands: [[UInt8]] { lock.withLock { _commands } }
    var startCount: Int { lock.withLock { _startCount } }

    func start() { lock.withLock { _startCount += 1 } }
    func stop() {}
    func sendCommand(_ command: [UInt8]) { lock.withLock { _commands.append(command) } }
    func sendRaw(_ bytes: [UInt8]) {}
    func setWriteTrace(_ trace: (@Sendable ([UInt8]) -> Void)?) {}

    func attach() { onDeviceAttached?() }
    func detach() { onDeviceDetached?() }
}

/// 用户能感知的行为契约测试:按键路由决策表 / 亮度互斥与涂黑 / 配置变更语义。
/// 这些是「手感」所在,此前零覆盖;字节层协议反而过度服务(测试金字塔纠偏)。
@Suite("行为契约")
@MainActor
struct BehaviorContractTests {
    // MARK: 公共脚手架

    /// 临时配置(注入路径,绝不触碰真实用户配置)
    private func makeTempConfig() -> ConfigStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-test-\(UUID().uuidString).json")
        return ConfigStore(contentsOf: url)
    }

    private func makeRunningDevice() async -> (DeviceController, FakeTransport) {
        let fake = FakeTransport()
        let controller = DeviceController(transport: fake)
        controller.start()
        fake.attach()
        await settle() // 状态迁移走 dispatch 回调,不等 settle 断言会扑空
        return (controller, fake)
    }

    /// 等待 dispatch 队列上的状态迁移落地(与状态机测试同款手法)
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// 造一台连着设备、配置好 N 页的完整测试环境(路由器 + 亮度域 + 场景域)
    private func makeRouter(pages: Int = 2) async -> (KeyPressRouter, DeviceController, ConfigStore, FakeTransport) {
        let (controller, fake) = await makeRunningDevice()
        let config = makeTempConfig()
        while config.currentScene.pages.count < pages {
            config.addPage(toSceneIndex: 0)
        }
        let brightness = BrightnessCoordinator(device: controller, config: config)
        let router = KeyPressRouter(
            device: controller,
            config: config,
            pluginHost: PluginHostModel(),
            heatmap: KeyboardHeatmapAnimator(),
            monitorInput: MonitorInputAnimator(),
            pressPulse: PressPulseAnimator(),
            brightness: brightness,
            sceneRouter: SceneRouter(config: config, device: controller)
        )
        return (router, controller, config, fake)
    }

    // MARK: 按键路由决策表

    @Test("熄屏态:按下沿只唤醒,不产生动作")
    func screenOffPressWakesWithoutAction() async {
        let (router, device, config, _) = await makeRouter()
        config.updateKey(KeyConfig(title: "下一页", action: .nextPage), at: 0)
        device.screenOff()
        #expect(device.isScreenOff)

        router.handle(KeyEvent(row: 0, column: 0, phase: .down))
        #expect(!device.isScreenOff, "按下沿应唤醒")
        #expect(config.currentPageIndex == 0, "唤醒的该次按压不产生翻页")
    }

    @Test("0% 涂黑:按下沿点亮到最近亮度并照常触发动作")
    func blackedPressPeeksAndActs() async {
        let (router, device, config, _) = await makeRouter()
        let brightness = BrightnessCoordinator(device: device, config: config)
        config.updateKey(KeyConfig(title: "下一页", action: .nextPage), at: 0)
        config.sliderZeroBlacksKeys = true
        brightness.setBrightness(0) // 触发涂黑
        #expect(device.keysBlacked)

        router.handle(KeyEvent(row: 0, column: 0, phase: .down))
        #expect(!device.keysBlacked, "按下沿先点亮")
        #expect(config.currentPageIndex == 1, "动作照常触发")
    }

    @Test("翻页动作只在按下沿触发,抬起沿不重复")
    func pageActionDownEdgeOnly() async {
        let (router, _, config, _) = await makeRouter()
        config.updateKey(KeyConfig(title: "下一页", action: .nextPage), at: 0)

        router.handle(KeyEvent(row: 0, column: 0, phase: .down))
        #expect(config.currentPageIndex == 1)
        router.handle(KeyEvent(row: 0, column: 0, phase: .up))
        #expect(config.currentPageIndex == 1, "抬起沿不得重复执行")
    }

    @Test("纯显示键(页面指示/统计)按压无任何状态变化")
    func displayOnlyKeysAreNoOps() async {
        let (router, _, config, _) = await makeRouter()
        config.updateKey(KeyConfig(title: "N/M", action: .pageIndicator), at: 0)
        config.updateKey(KeyConfig(title: "GPU", action: .stat(.gpu)), at: 1)
        let before = config.currentPageIndex

        router.handle(KeyEvent(row: 0, column: 0, phase: .down))
        router.handle(KeyEvent(row: 0, column: 1, phase: .down))
        #expect(config.currentPageIndex == before, "显示键不得改变导航状态")
    }

    // MARK: 亮度互斥与涂黑

    @Test("0% 涂黑与拖离 0% 恢复(滑杆 0% 涂黑开启时)")
    func zeroBlacksAndRecover() async {
        let (device, _) = await makeRunningDevice()
        let config = makeTempConfig()
        let brightness = BrightnessCoordinator(device: device, config: config)
        config.sliderZeroBlacksKeys = true

        brightness.setBrightness(0)
        #expect(device.keysBlacked)
        brightness.setBrightness(40)
        #expect(!device.keysBlacked, "拖离 0 应立即恢复键面")
    }

    @Test("自动熄屏与亮度跟随互斥(双向归一化)")
    func autoScreenOffAndFollowMutuallyExclusive() async {
        let (device, _) = await makeRunningDevice()
        let config = makeTempConfig()
        let brightness = BrightnessCoordinator(device: device, config: config)

        // 方向一:开自动熄屏 → 跟随让路(熄屏值保留,那是用户选的)
        brightness.setAutoScreenOffMinutes(5)
        #expect(!config.followSystemBrightness, "自动熄屏开启应关闭跟随")
        #expect(config.autoScreenOffMinutes == 5)

        // 方向二:开跟随 → 自动熄屏被强制归零(跟随的 0% 涂黑承担夜间变暗)
        brightness.setFollowSystemBrightness(true)
        #expect(config.followSystemBrightness)
        #expect(config.autoScreenOffMinutes == 0, "跟随开启应强制关闭自动熄屏")
    }

    // MARK: 配置变更语义

    @Test("删除非当前场景:视野保持,且无需整页重渲")
    func deleteOtherSceneKeepsView() throws {
        let config = makeTempConfig()
        config.addScene()
        config.addScene()
        let firstID = try #require(config.currentScene.id) // 场景 1(正在看)
        let targetID = try #require(config.config.scenes[2].id) // 场景 3(要删的)
        config.setCurrentSceneIndex(0)

        let wasCurrent = config.deleteScene(id: targetID)
        #expect(!wasCurrent)
        #expect(config.currentScene.id == firstID, "视野场景不得被删别人的操作带走")
    }

    @Test("删除正在看的场景:落到同位置的新场景")
    func deleteCurrentSceneLandsAtSamePosition() throws {
        let config = makeTempConfig()
        config.addScene()
        config.addScene()
        config.setCurrentSceneIndex(1) // 正在看场景 2
        let currentID = try #require(config.currentScene.id)

        let wasCurrent = config.deleteScene(id: currentID)
        #expect(wasCurrent)
        #expect(config.currentSceneIndex == 1, "应落到原位置(已前移的场景 3)")
    }

    @Test("复制场景:页 id 全部重生成,导航不再跳回原场景")
    func duplicateSceneRegeneratesPageIDs() throws {
        let config = makeTempConfig()
        let originalID = try #require(config.currentScene.id)
        let originalPages = config.currentScene.pages.map(\.id)
        let copyID = try #require(config.duplicateScene(id: originalID))

        let copy = try #require(config.config.scenes.first { $0.id == copyID })
        let original = try #require(config.config.scenes.first { $0.id != copyID })
        for (a, b) in zip(original.pages, copy.pages) {
            #expect(a.id != b.id, "克隆页不得与原场景共享 id")
        }
        #expect(originalPages.count == copy.pages.count)
    }

    @Test("addPage 25 页封顶")
    func addPageCappedAt25() {
        let config = makeTempConfig()
        for _ in 0..<24 {
            config.addPage(toSceneIndex: 0)
        }
        #expect(config.currentScene.pages.count == 25)
        #expect(config.addPage(toSceneIndex: 0) == nil, "超上限应拒绝")
        #expect(config.currentScene.pages.count == 25)
    }

    @Test("损坏配置:归档留底 + 回退默认(数据完整性守卫)")
    func corruptConfigArchivedAndReset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ 这不是 JSON ".utf8).write(to: url)

        let config = ConfigStore(contentsOf: url)
        #expect(config.sceneCount >= 1, "损坏后应回退到可用默认配置")

        let archived = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.corrupt-") }
        #expect(archived.count == 1, "损坏原文件必须归档留底")
    }
}

extension BehaviorContractTests {
    /// 导航方向过渡回调(§6.34):四种导航案触发 onNavTransition,kind/offset 正确
    @Test("导航过渡回调:kind 与 offset 随动作")
    func navTransitionCallback() async {
        let (router, _, config, fake) = await makeRouter(pages: 3)
        var events: [(String, Int)] = []
        router.onNavTransition = { _, kind, offset, _ in
            events.append((kind == .page ? "page" : "scene", offset))
        }
        _ = config
        let keyEvent = { (row: Int, col: Int) in KeyEvent(row: row, column: col, phase: .down) }
        // 构造带导航动作的键:直接经 handleDeviceAction 的公开入口 handle 走保留槽配置
        router.handle(keyEvent(2, 4)) // 槽 15 = 下一页
        router.handle(keyEvent(2, 3)) // 槽 14 = 下一场景
        await settle()
        _ = fake
        #expect(events.count >= 2, "两个导航键应各触发一次过渡回调: \(events)")
        if events.count >= 2 {
            #expect(events[0].0 == "page" && events[0].1 == 1)
            #expect(events[1].0 == "scene" && events[1].1 == 1)
        }
    }
}
