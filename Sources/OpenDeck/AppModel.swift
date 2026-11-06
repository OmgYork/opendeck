import AppKit
import Observation
import os
import StreamDockKit

/// 应用级模型:粘合驱动层(DeviceController)与配置层(ConfigStore)。
/// 职责:按键事件 → 动作分发、键面渲染上屏、亮度同步、官方 app 冲突检测。
@MainActor
@Observable
final class AppModel {
    /// 官方 StreamDock.app 的 bundle id(定义在 SystemIntegration)
    static let officialBundleID = SystemIntegration.officialBundleID

    /// 设备控制器:生产 = HIDTransport;虚拟模式(OPDECK_VIRTUAL=1) = VirtualTransport
    /// (无硬件全状态机,报文丢弃——UI 验证/演示不再抢真机)
    private(set) var device: DeviceController

    private static func makeDevice() -> DeviceController {
        if useVirtualDevice {
            return DeviceController(transport: VirtualTransport())
        }
        return DeviceController()
    }
    // MARK: - 固定保留槽(策略见 ReservedSlots)

    /// 保留槽类型(EditorView 以「== nil」判断用户槽，故保留同名 typealias)
    typealias ReservedSlot = ReservedSlots.Slot

    /// 该格是否为保留槽
    static func reservedSlot(at index: Int) -> ReservedSlot? {
        ReservedSlots.slot(at: index)
    }

    /// 键位最终生效配置:保留槽强制保留瓷贴,其余读用户配置
    static func resolvedKeyConfig(at index: Int, config: ConfigStore) -> KeyConfig {
        ReservedSlots.keyConfig(at: index, config: config)
    }

    /// 首页(第一场景第一页)键位配置:调色盘「自定义」镜像的取数源。
    /// 固定读首页而非当前页——在任何场景/页下,镜像都是同一份「我的常用键」,
    /// 否则切到别的页,镜像会变成那边大概率还空着的槽位,复制语义就断了。
    func homeKeyConfig(at index: Int) -> KeyConfig? {
        guard config.config.scenes.indices.contains(0),
              config.config.scenes[0].pages.indices.contains(0),
              config.config.scenes[0].pages[0].keys.indices.contains(index) else { return nil }
        return config.config.scenes[0].pages[0].keys[index]
    }

    private static let paletteLog = Logger(subsystem: "opendeck", category: "palette")

    /// 调色盘落键:把载荷绑到该键(保留槽不可放置),并即时上屏。
    /// 自 EditorView 下沉到模型层——复刻/草稿消费/插件实例政策集中于此,可测可复用。
    /// 载荷格式见 FunctionPaletteCatalog 头注释,另支持:
    /// - "slot:<index>":整键复刻**首页**该槽的配置(与自定义镜像磁贴渲染同源);
    ///   插件键复刻生成**新 contextID**(克隆 = 新实例,两键不再互抢实例表唯一身份)
    /// - "draft:<kind>":消费 templateDrafts 就绪态(一次性,落键即清)
    func bindPayload(_ raw: String, at index: Int) {
        guard let key = Self.landingConfig(
            payload: raw, targetIndex: index,
            current: config.keyConfig(at: index),
            homeKey: { homeKeyConfig(at: $0) },
            draft: { config.templateDrafts[$0] }
        ) else {
            Self.paletteLog.info("palette bind rejected unknown payload \(raw, privacy: .public)")
            return
        }
        if raw.hasPrefix("draft:"),
           let kind = KeyTemplate(rawValue: String(raw.dropFirst("draft:".count))) {
            setTemplateDraft(kind, nil) // 一次性:落键即消费草稿(持久化清除)
        }
        config.updateKey(key, at: index)
        applyKey(at: index)
    }

    /// 落键政策(纯函数,可测):payload → 目标槽位应有的完整 KeyConfig;nil = 拒绝。
    /// - 保留槽(目标或镜像源)一律拒绝
    /// - "slot:<index>":整键复刻**首页**该槽配置(含底色);插件键生成新 contextID(克隆 = 独立实例)
    /// - "draft:<kind>":就绪模板整份落键(标题/动作/图标),底色沿用目标槽现状,清模板占位
    /// - 其余走 FunctionPaletteCatalog(命令/复合/即用动作);底色/图标沿用目标槽现状
    static func landingConfig(
        payload: String, targetIndex: Int, current: KeyConfig,
        homeKey: (Int) -> KeyConfig?, draft: (KeyTemplate) -> KeyConfig?
    ) -> KeyConfig? {
        guard Self.reservedSlot(at: targetIndex) == nil else { return nil }
        var key = current
        if payload.hasPrefix("slot:"),
           let source = Int(payload.dropFirst("slot:".count)),
           Self.reservedSlot(at: source) == nil,
           let home = homeKey(source),
           !isEmptyMirrorKey(home) {
            key = home
            if case .plugin(let pluginID, let actionUUID, _) = key.action {
                key.action = .plugin(pluginID: pluginID, actionUUID: actionUUID,
                                     contextID: UUID().uuidString)
            }
            return key
        }
        if payload.hasPrefix("draft:"),
           let kind = KeyTemplate(rawValue: String(payload.dropFirst("draft:".count))),
           let ready = draft(kind) {
            key.action = ready.action
            key.title = ready.title
            key.animation = ready.animation
            key.iconPath = ready.iconPath
            key.template = nil
            return key
        }
        guard let item = FunctionPaletteCatalog.item(forPayload: payload) else { return nil }
        key.action = item.action
        // 落下即写短标签:槽位里原有的数字占位(3…15)不是用户标题,留着会读成"5 号键在调亮度"
        key.title = item.title
        key.animation = item.animation
        key.template = item.template
        return key
    }

    /// 空键判定(slot: 复刻源专用):首页槽位是空的时整键复刻 = 把目标键静默清空,拒绝。
    /// UI 侧(调色盘自定义磁贴)同步禁拖并压暗
    static func isEmptyMirrorKey(_ key: KeyConfig) -> Bool {
        key.action == nil && key.iconPath == nil && key.animation == nil
            && key.template == nil && key.title.isEmpty
    }

    let config = ConfigStore()
    let pluginHost = PluginHostModel()
    /// 内建动效键面:显示器输入源(Mac ↔ PC)。全局只有一路输入状态,故单实例。
    /// 虚拟设备模式(无硬件开发/UI 验证):环境变量 OPDECK_VIRTUAL=1 或
    /// Info.plist OpenDeckUseVirtualDevice 触发。设备层全状态机照跑,报文丢弃
    static let useVirtualDevice: Bool = {
        if ProcessInfo.processInfo.environment["OPDECK_VIRTUAL"] == "1" { return true }
        return Bundle.main.infoDictionary?["OpenDeckUseVirtualDevice"] as? Bool == true
    }()

    let monitorInput = MonitorInputAnimator()
    /// 通用按压脉冲(§6.32):多键,静息帧 = 常规渲染产物,按压沿闪亮+微放大 0.66s
    let pressPulse = PressPulseAnimator()
    /// 瓷贴过渡帧(§6.33):睡眠锁扣开合
    let tileFX = TileFXPlayer()
    /// 图像模式 toggle 键(§6.39):玩家1 ↔ 阅读,静息显当前档,按压切换播扫动
    let picMode = PicModeAnimator()

    // MARK: 启动方式与构建指纹(§6.37)

    /// 当前启动方式(面板三态 Picker 绑定)
    var launchMode: LaunchMode { system.launchMode }
    var isAppBundleForm: Bool { system.isAppBundleForm }
    func setLaunchMode(_ mode: LaunchMode) { system.setLaunchMode(mode) }

    /// 构建指纹(commit·state 时间):Info.plist 由 make-app.sh 写入。
    /// 「运行中 = HEAD」的肉眼/截图判定面——本会话两次被旧二进制误诊的解药
    static func buildFingerprint(info: [String: Any]) -> String {
        let commit = info["OpenDeckBuildCommit"] as? String ?? "?"
        let state = info["OpenDeckBuildState"] as? String ?? "?"
        let time = info["OpenDeckBuildTime"] as? String ?? "?"
        return "\(commit)·\(state) \(time)"
    }

    var buildFingerprint: String {
        Self.buildFingerprint(info: Bundle.main.infoDictionary ?? [:])
    }
    /// 睡眠锁上次渲染的视觉态(翻转 → 播锁扣过渡)
    private var lastSleepGuardVisual: SleepGuardTileRenderer.VisualState?
    /// 内建读数键面:键盘热力图(KeyAnalyze)。同样是单实例,只服务当前页那一颗。
    let heatmap = KeyboardHeatmapAnimator()
    /// Stats 瓷贴节拍器(CPU/GPU/温度,槽位随当前页配置对账,可放任意键位)
    let statTiles = StatTileAnimator()
    /// 亮度域:背光、内屏亮度读取、跟随轮询、0% 涂黑与回涂黑、空闲熄屏看门狗
    let brightness: BrightnessCoordinator
    /// 场景/页面路由域:两级导航、场景与页面增删、按前台应用联动
    let sceneRouter: SceneRouter
    /// 系统集成域:官方 app 冲突检测、登录项
    let system = SystemIntegration()
    /// 日志环:stdout + oslog + 内存环
    let logs = LogRing()
    /// 按键事件 → 动作分发域
    let keyRouter: KeyPressRouter

    /// animator 回调统一在 init 挂接(接入约定):编辑器 WindowGroup 的 `.onAppear`
    /// 会先于 `.task { start() }` 调 `applyPageToDevice()`,若等到 start() 才接 hook,
    /// 首次 attach 的帧会被丢掉。三个 animator 同一时机,不在此处区分。
    init() {
        // 设备层先行;局部变量贯穿构造(两段式初始化:全部存储属性就位前不读 self)
        let device = Self.makeDevice()
        self.device = device
        onboardingNeeded = config.isFreshInstall
        // 先构造全部协调器(捕获 self 的前提是存储属性已全部初始化),再统一挂钩子
        brightness = BrightnessCoordinator(device: device, config: config)
        sceneRouter = SceneRouter(config: config, device: device)
        keyRouter = KeyPressRouter(
            device: device, config: config, pluginHost: pluginHost,
            heatmap: heatmap, monitorInput: monitorInput, pressPulse: pressPulse,
            picMode: picMode, brightness: brightness, sceneRouter: sceneRouter
        )
        keyRouter.onNavTransition = { [weak self] index, kind, offset, fromIndex in
            guard let self else { return }
            // 方向过渡帧:场景卡片拨动/页键辉光沿轨滑一档,收尾回新页态静息
            // (applyKey 已在 switch 内先跑完,静息帧即新页态;过渡帧从旧位滑向它)
            let pageCount = kind == .page ? self.config.currentScene.pages.count : 0
            let final: CGImage?
            if kind == .page {
                final = NavTileRenderer.image(kind: kind, pageCount: pageCount,
                                              pageIndex: self.config.currentPageIndex)
            } else {
                final = NavTileRenderer.image(kind: kind)
            }
            if let frames = NavTileRenderer.transitionFrames(kind: kind, offset: offset,
                                                             pageCount: pageCount, fromIndex: fromIndex),
               let final {
                self.tileFX.play(index: index, frames: frames, final: final)
            }
        }
        system.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        brightness.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        sceneRouter.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        sceneRouter.applyPage = { [weak self] in
            self?.applyPageToDevice()
        }
        sceneRouter.isEditorWindowVisible = { [weak self] in
            self?.editorWindowVisible ?? true
        }
        keyRouter.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        keyRouter.onPressedChange = { [weak self] index, down in
            guard let self else { return }
            // @Observable 靠属性赋值触发观测,集合原地增删不生效,须整体重赋
            self.pressedKeyIndices = down
                ? self.pressedKeyIndices.union([index])
                : self.pressedKeyIndices.subtracting([index])
        }
        keyRouter.onSleepGuard = { [weak self] index in
            Task { await self?.toggleSleepGuard(at: index) }
        }
        monitorInput.onFrame = { [weak self] image in
            guard let self, let index = self.monitorInput.activeIndex else { return }
            self.setKeyImage(index: index, image: image)
        }
        monitorInput.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        heatmap.onFrame = { [weak self] image in
            guard let self, let index = self.heatmap.activeIndex else { return }
            self.setKeyImage(index: index, image: image)
        }
        heatmap.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        statTiles.onFrame = { [weak self] index, image in
            self?.setKeyImage(index: index, image: image)
        }
    }

    /// 官方 app 是否正在运行(驱动编辑器顶部的冲突警示条)。
    /// 判据在 SystemIntegration;存储留在本类,因为 EditorView/OpenDeckApp 在 body 里读它
    private(set) var officialAppRunning = false
    /// 当前物理按下的键(index 集合)——UI 键帽同步凹陷,验证「按哪颗亮哪颗」
    private(set) var pressedKeyIndices: Set<Int> = []
    /// 实时键面镜像(单键粒度):每键一个 @Observable 槽,只有读过该槽的 KeycapView 因其变化重绘。
    /// 首版把全部键面塞进一个字典属性,任一键推图=整网格重渲+逐键磁盘 IO,触控板滚动被打断(§6.15)
    let keyImageSlots: [KeyImageSlot] = (0..<(StreamDock293S.rows * StreamDock293S.columns)).map { _ in KeyImageSlot() }
    /// 最近设备日志(尾部最新),仅供状态栏展示,环形保留一屏即可
    var recentLogs: [String] { logs.recentLogs }
    /// 合盖休眠锁状态缓存(nil = 还没读到)。只作渲染用;真实值以 pmset 为准,
    /// 每次切换后由 SleepGuard 的回读结果覆盖,不做乐观翻转。
    private(set) var sleepGuardEnabled: Bool?
    /// sudoers 规则缺失(授权失败):键帽常驻「未授权」态,直到规则装好且切换成功
    private(set) var sleepGuardUnauthorized = false
    /// 「缺授权」提示每会话只弹一次:反复按键不该反复打断
    private var didWarnSleepGuard = false
    /// 模板磁贴就绪态(持久化在 config.templateDrafts):点击模板磁贴配置出的动作。
    /// 一次性:拖拽落键即消费(落键清除),磁贴复原回占位态;重启后草稿仍在,直到被使用或清除
    var templateDrafts: [KeyTemplate: KeyConfig] { config.templateDrafts }

    /// 保存/清除模板草稿(nil = 清除)
    func setTemplateDraft(_ kind: KeyTemplate, _ key: KeyConfig?) {
        config.setTemplateDraft(kind, key)
    }

    /// 首次启动引导:仅 config.json 当次不存在(全新安装)时为真,关闭后持久记忆
    let onboardingNeeded: Bool

    private var started = false
    /// 单实例锁(见 InstanceLock):acquired 后持有到进程退出
    private var instanceLock: InstanceLock?
    /// 实例锁文件路径(应用支持目录,与 config.json 同级)
    static let instanceLockPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenDeck/.instance.lock").path
    /// 观察者与进程同生命周期,无需移除;保留 token 仅为可测试性
    private var workspaceObservers: [NSObjectProtocol] = []
    /// App Nap 断言:菜单栏 app 长期无窗口时会被整进程挂起,插件 webview 的
    /// 定时器/轮询随之冻结(HTML 家族无界面可见性,尤甚)。设备心跳与插件宿主
    /// 是本 app 的存在意义,进程常驻即业务,断言与进程同生命周期。
    private var activityToken: NSObjectProtocol?

    var latestLog: String? { logs.latest }

    // MARK: - 配置备份导出/导入(§6.29)

    /// 导出整机备份(config + 插件参数 + 插件本体 + 图标)到用户指定的 zip
    func exportBackup(to destination: URL) throws -> ConfigPorter.ExportReport {
        let report = try ConfigPorter.exportConfig(
            to: destination, config: config, pluginHost: pluginHost,
            iconsBase: ConfigPorter.appSupportRoot
        )
        appendLog("备份已导出:\(destination.lastPathComponent) 插件 \(report.pluginCount) 个、参数文档 \(report.settingsDocumentCount) 份")
        return report
    }

    /// 导入校验 + 暂存(不动运行中的实例;确认后重启生效)
    func stageBackupImport(from archive: URL) throws -> ConfigPorter.ImportSummary {
        let summary = try ConfigPorter.validateAndStageImport(from: archive)
        appendLog("备份导入已暂存:场景 \(summary.sceneCount)、插件 \(summary.pluginCount) 个(重启后生效)")
        return summary
    }

    // MARK: - 键位剪贴板(右键复制/粘贴,官方 App 同款;§6.30)

    /// 会话内存剪贴板(不进系统粘贴板:避免与通用 ⌘C/⌘V 语义互相踩)
    @ObservationIgnored private(set) var keyClipboard: KeyConfig?

    func copyKey(at index: Int) {
        guard AppModel.reservedSlot(at: index) == nil else { return }
        keyClipboard = AppModel.resolvedKeyConfig(at: index, config: config)
        appendLog("已复制第 \(index + 1) 键(会话内有效)")
    }

    func pasteKey(at index: Int) {
        guard let clip = keyClipboard, AppModel.reservedSlot(at: index) == nil else { return }
        config.updateKey(Self.pastedConfig(clip: clip, onto: config.keyConfig(at: index)), at: index)
        applyKey(at: index)
        appendLog("已粘贴到第 \(index + 1) 键")
    }

    func clearKeyFromContextMenu(at index: Int) {
        guard AppModel.reservedSlot(at: index) == nil else { return }
        var key = config.keyConfig(at: index)
        key.action = nil
        key.animation = nil
        key.title = ""
        key.iconPath = nil
        key.template = nil
        config.updateKey(key, at: index)
        applyKey(at: index)
    }

    /// 粘贴政策(纯函数,可测):整键复刻含底色;插件键生成新 contextID(克隆 = 独立实例,
    /// 与 slot: 复刻同一条铁律——共享 contextID 会互抢实例表唯一身份)
    static func pastedConfig(clip: KeyConfig, onto current: KeyConfig) -> KeyConfig {
        var key = clip
        if case .plugin(let pluginID, let actionUUID, _) = key.action {
            key.action = .plugin(pluginID: pluginID, actionUUID: actionUUID,
                                 contextID: UUID().uuidString)
        }
        return key
    }

    // MARK: - 启动自动备份(§6.30)

    /// 自动备份目录(backups/,与 config.json 同级)
    static var autoBackupRoot: URL {
        ConfigPorter.appSupportRoot.appendingPathComponent("backups", isDirectory: true)
    }

    func runAutoBackupIfNeeded() {
        ConfigPorter.runAutoBackupIfNeeded(
            config: config, pluginHost: pluginHost,
            backupRoot: Self.autoBackupRoot,
            configFile: config.configFileURL
        )
    }

    // MARK: - 生命周期

    /// 幂等启动:检测官方 app、接管按键回调、同步已存亮度、开始热插拔监控。
    func start() {
        guard !started else { return }
        started = true

        // 熄屏/涂黑 → 插件推拍抑制:设备看不见的帧一帧都不用算
        device.onOutputSuppressionChange = { [weak self] suppressed in
            self?.pluginHost.setOutputSuppressed(suppressed)
        }
        // 单实例守卫(见 InstanceLock):双实例并存会互相整文件覆盖配置,先于一切状态建立
        switch InstanceLock.acquire(path: Self.instanceLockPath) {
        case .acquired(let lock):
            instanceLock = lock // 持有到进程退出
        case .locked:
            // 崩溃自愈 agent 的 RunAtLoad 在「安装时本实例已在跑」会拉起第二实例:
            // 该形态静默退出(弹对话框会在每次安装时打扰用户);用户手动双开才弹窗
            if ProcessInfo.processInfo.environment["OPDECK_LAUNCHED_BY_AGENT"] == "1" {
                exit(0)
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "OpenDeck 已在运行"
            alert.informativeText = "同一台 Mac 只允许一个 OpenDeck 实例——调试实例与正式版并存会互相覆盖配置文件。请先退出已运行的实例。"
            alert.runModal()
            exit(0)
        case .unavailable:
            appendLog("实例锁文件不可用,单实例防御未生效:\(Self.instanceLockPath)")
        }
        // 配置域异常(保存失败/损坏归档失败)上行到运行日志环:静默失败时代覆盖配置
        config.onAnomaly = { [weak self] message in
            self?.appendLog(message)
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "OpenDeck:设备心跳与插件宿主常驻"
        )
        // Stats 集成:瓷贴节拍器接管采样与整帧刷新(设备 + UI 镜像同源);槽位随当前页配置对账
        statTiles.start()
        syncStatSlots()

        refreshOfficialAppFlag()
        observeWorkspaceApplications()

        pluginHost.hooks.draw = { [weak self] index, image in
            guard let self else { return }
            self.setKeyImage(index: index, image: image)
        }
        pressPulse.onFrame = { [weak self] index, image in
            guard let self else { return }
            self.setKeyImage(index: index, image: image)
        }
        tileFX.onFrame = { [weak self] index, image in
            guard let self else { return }
            self.setKeyImage(index: index, image: image)
        }
        picMode.onFrame = { [weak self] index, image in
            guard let self else { return }
            self.setKeyImage(index: index, image: image)
        }
        picMode.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        picMode.applyDDC = { command in
            await ActionRunner.run(.monitor(command))
        }
        pluginHost.hooks.backgroundColor = { [weak self] index in
            self?.config.keyConfig(at: index).backgroundColorHex ?? "#3B4252"
        }
        pluginHost.hooks.open = { url in NSWorkspace.shared.open(url) }
        pluginHost.hooks.activateApp = { [weak self] bundleID in
            // openApplication(等价 open -a):运行中=激活置前,未运行=启动;失败记日志不弹窗
            let workspace = NSWorkspace.shared
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
                self?.appendLog("状态灯激活目标未安装:\(bundleID)")
                return
            }
            // Logger 本身 Sendable;先取值再进 Sendable 回调,避免闭包内触碰 MainActor 隔离的静态属性
            let log = LogRing.oslog
            workspace.openApplication(at: url, configuration: .init()) { _, error in
                if let error { log.error("激活 \(bundleID, privacy: .public) 失败:\(error.localizedDescription, privacy: .public)") }
            }
        }
        pluginHost.hooks.log = { [weak self] line in
            self?.appendLog(line)
        }
        pluginHost.start()
        // 启动自检摘要(§6.37):构建指纹 + 配置/插件盘点,一行进运行日志——
        // agent 与排障的第一眼事实(「跑的是哪个构建」曾两次误诊本会话)
        let pluginNames = pluginHost.installedPlugins.map { $0.manifest.pluginUUID }
            .joined(separator: ",")
        appendLog("启动自检:构建 \(buildFingerprint) · 场景 \(config.sceneCount) 页 \(config.config.scenes.reduce(0) { $0 + $1.pages.count }) · 插件 \(pluginHost.installedPlugins.count)[\(pluginNames)] · 启动方式 \(launchMode.label)")
        // 启动自动备份(§6.30):配置自上次备份有变才打一份,滚动保留 10 份。
        // 延迟 2s 等插件清单装载完成(备份要带插件本体)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.runAutoBackupIfNeeded()
        }
        // 动效键面(animator)的帧回调已在 init 挂接,这里只启动各自的节拍

        device.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        device.onKeyEvent = { [weak self] event in
            self?.keyRouter.handle(event)
        }

        // 先同步亮度再 start():设备连接校准时控制器会以已存值设置背光
        device.setBrightness(config.config.brightness)
        // 对位补偿须在任何键面下发前就位(连接校准会按缓存全量重画)
        device.setGlassOffset(x: config.glassOffset.x, y: config.glassOffset.y,
                              zoom: config.glassOffset.zoom)
        device.start()
        // 亮度域:跟随轮询 → 互斥归一化 → 空闲看门狗(顺序与拆分前一致,见协调器 start())
        brightness.start()
        // 合盖休眠锁:读真实状态并回显到绑定键(nil 期间键面显示「⋯」)
        refreshSleepGuardState()
    }

    /// 应用退出时收割插件进程并释放设备,挂到 applicationWillTerminate
    func handleAppQuit() {
        pluginHost.shutdown()
        device.shutdown()
    }

    // MARK: - 场景与页面(两级，转发到场景路由协调器)

    /// 切换到指定场景;同场景重复切换无副作用
    func switchScene(to id: UUID) {
        sceneRouter.switchScene(to: id)
    }

    /// 循环切换场景(上一场景/下一场景;落到目标场景第一页)
    func switchScene(offset: Int) {
        sceneRouter.switchScene(offset: offset)
    }

    /// 切换到指定页(跨场景按 Page.id 定位;圆点点击直达用)
    func switchPage(to id: UUID) {
        sceneRouter.switchPage(to: id)
    }

    /// 场景内循环翻页(上一页/下一页)
    func switchPage(offset: Int) {
        sceneRouter.switchPage(offset: offset)
    }

    func addScene() {
        sceneRouter.addScene()
    }

    func duplicateScene(id: UUID) {
        sceneRouter.duplicateScene(id: id)
    }

    /// 删除场景;若删的是当前场景(索引被回退),设备需重画新当前场景
    func deleteScene(id: UUID) {
        sceneRouter.deleteScene(id: id)
    }

    /// 当前场景加一页(圆点 +1)并切到新页
    func addPageToCurrentScene() {
        sceneRouter.addPageToCurrentScene()
    }

    /// 给指定场景加一页(圆点 +1)并切到该场景新页
    func addPage(toScene id: UUID) {
        sceneRouter.addPage(toScene: id)
    }

    /// 删除当前场景内的一页(每场景至少保留 1 页)
    func deletePageInCurrentScene(at pageIndex: Int) {
        sceneRouter.deletePageInCurrentScene(at: pageIndex)
    }

    // MARK: - 场景联动(前台应用自动切换场景)

    /// 编辑器窗口是否可见:官方语义为「应用窗口关闭时」才做前台切换,配置期间不打扰。
    /// 存储留在本类(会被 EditorView 写入的可观察属性),路由器按下标读取。
    var editorWindowVisible = true

    /// 前台应用变化:优先切到绑定了该应用的场景;无绑定且设了默认场景则回默认场景
    func autoSwitchPageForFrontmostApp() {
        sceneRouter.autoSwitchPageForFrontmostApp()
    }

    /// 已安装应用清单(场景联动下拉用;/Applications + /System/Applications,按名称排序)
    nonisolated static func installedApps() -> [(bundleID: String, name: String)] {
        SceneRouter.installedApps()
    }

    // MARK: - 合盖休眠锁(设备控制动作的分发已移至 KeyPressRouter)

    /// 翻转合盖休眠锁:执行 → 回读 → 更新缓存并重画该键。
    /// 失败不静默:键面回落到真实状态,状态栏留日志,并提示一次授权问题。
    /// 睡眠锁切换在飞标志:pmset 子进程 + 回读要几百毫秒,快速连按的两个并发 toggle
    /// 会互相读到旧值(第二次按压「没反应」)。单飞:在飞期间的按压合并等待下一轮
    private var sleepGuardToggleInFlight = false

    private func toggleSleepGuard(at index: Int) async {
        guard !sleepGuardToggleInFlight else {
            appendLog("合盖休眠锁切换进行中,忽略本次按压")
            return
        }
        sleepGuardToggleInFlight = true
        defer { sleepGuardToggleInFlight = false }
        switch await SleepGuard.toggle() {
        case .success(let enabled):
            sleepGuardEnabled = enabled
            sleepGuardUnauthorized = false
            appendLog("合盖休眠锁 → \(enabled ? "开(合盖不睡)" : "关(合盖休眠)")")
            applyKey(at: index)
        case .failure(let error):
            sleepGuardEnabled = await SleepGuard.currentState()
            // 未授权是可持续状态:键帽常驻「未授权」提示,比一次性弹窗更有解释力
            if case .authorizationMissing = error {
                sleepGuardUnauthorized = true
            }
            appendLog("合盖休眠锁切换失败:\(error.localizedDescription)")
            applyKey(at: index)
            presentSleepGuardAlertOnce(message: error.localizedDescription)
        }
    }

    /// 启动时读一次真实状态(异步,不拖慢设备连接),只重画绑了这个动作的键
    private func refreshSleepGuardState() {
        Task { [weak self] in
            let state = await SleepGuard.currentState()
            guard let self else { return }
            self.sleepGuardEnabled = state
            for index in 0..<(StreamDock293S.rows * StreamDock293S.columns) {
                if case .sleepGuard = Self.resolvedKeyConfig(at: index, config: self.config).action {
                    self.applyKey(at: index)
                }
            }
        }
    }

    private func presentSleepGuardAlertOnce(message: String) {
        guard !didWarnSleepGuard else { return }
        didWarnSleepGuard = true
        // 精确规则:只放行 pmset disablesleep 的 0/1 两个取值,其余 sudo 权限不变
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let installCommand = "echo '\(rule)' | sudo tee \(SleepGuard.sudoersPath)"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "合盖休眠锁不可用"
        alert.informativeText = """
            \(message)

            一次性安装免密规则(只放行 pmset disablesleep 的 0/1 两个取值,其余 sudo 权限不变)——终端执行:

            \(installCommand)

            执行后回到 OpenDeck 再按一次该键。
            """
        alert.addButton(withTitle: "复制命令")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(installCommand, forType: .string)
        }
    }

    // MARK: - 键面上屏

    /// 当前页 18 键全部渲染并下发
    func applyPageToDevice() {
        for index in 0..<(StreamDock293S.rows * StreamDock293S.columns) {
            applyKey(at: index)
        }
    }

    /// 单键重画:编辑保存后即时上屏;同时把插件动作的分配/移除同步给插件宿主
    /// (启动整页刷新、单键编辑、页面切换都会走到这里,是宿主实例与配置天然的对账点)
    func applyKey(at index: Int) {
        let row = index / StreamDock293S.columns
        let column = index % StreamDock293S.columns
        // 固定导航键:无视配置,强制导航动作(配置里这两格的内容不渲染、不建实例)
        let key = Self.resolvedKeyConfig(at: index, config: config)
        tileFX.stop(ifIndex: index) // 键变化清过渡场(睡眠锁/统计的过渡只属于自己的会话)
        pluginHost.syncKey(at: index, action: key.action)
        // 统计槽位对账:当前页的 .stat 键清单喂给节拍器(编辑/换页/切场景都会走到这里)
        syncStatSlots()
        // 统计键:整帧由瓷贴节拍器覆盖,这里先上占位帧(采样值或 "--");清除后走下方常规渲染覆盖旧帧。
        // 提前 return 前必须先摘掉别的 animator:该键原先是热力图/动效键时,
        // 不 detach 的话旧节拍器会持续出帧与统计帧打架
        if case .stat(let kind) = key.action {
            heatmap.detach(ifIndex: index)
            monitorInput.detach(ifIndex: index)
            pressPulse.detach(ifIndex: index)
            picMode.detach(ifIndex: index)
            if let image = statTiles.placeholderTile(kind: kind) {
                setKeyImage(index: index, image: image)
            }
            return
        }
        // 热力图键:整帧由读数键的 animator 驱动,同样跳过常规渲染。
        // 动效键改热力图键时旧 monitorInput 不摘会持续出帧打架(与 stat 分支同款,§6.25 修复①漏了这条)
        if case .keyboardHeatmap = key.action {
            monitorInput.detach(ifIndex: index)
            pressPulse.detach(ifIndex: index)
            picMode.detach(ifIndex: index)
            heatmap.attach(index: index, size: StreamDock293S.keySize(column: column))
            return
        }
        heatmap.detach(ifIndex: index)
        // 内建动效键:整帧由动画驱动,跳过常规「底色 + 底图 + 标题」渲染
        if key.animation == .monitorInput {
            pressPulse.detach(ifIndex: index)
            picMode.detach(ifIndex: index)
            monitorInput.attach(index: index, size: StreamDock293S.keySize(column: column))
            return
        }
        monitorInput.detach(ifIndex: index) // 同页其它键/换页后的旧动效键
        // 图像模式 toggle 键(§6.39):整帧由专用动画器驱动(显当前档,轮询对账)
        if key.animation == .picModeToggle {
            pressPulse.detach(ifIndex: index)
            picMode.attach(index: index)
            return
        }
        picMode.detach(ifIndex: index) // 键不再是图像模式键:摘动画器
        // 媒体键:暗夜仪表专用渲染(§6.33,忽略底色/标题配置);按压脉冲基帧 = 该渲染产物
        if case .mediaKey(let mediaKind) = key.action,
           let image = MediaTileRenderer.image(kind: mediaKind) {
            setKeyImage(index: index, image: image)
            if key.animation == .pressPulse {
                pressPulse.attach(index: index, base: image)
            } else {
                pressPulse.detach(ifIndex: index)
            }
            return
        }
        // 导航键(场景/页,含保留槽):暗夜仪表专用渲染(§6.34,忽略底色/标题配置)。
        // 页键带真实页态:点数 = 当前场景页数,辉光点 = 当前页(翻页跟随的视觉根源)
        if let navKind = NavTileRenderer.Kind(action: key.action) {
            let pageCount = navKind == .page ? config.currentScene.pages.count : 0
            let pageIndex = config.currentPageIndex
            if let image = NavTileRenderer.image(kind: navKind, pageCount: pageCount, pageIndex: pageIndex) {
                setKeyImage(index: index, image: image)
                return
            }
        }
        // 页面指示键:标题动态显示 "N/M",随页面切换自动刷新
        let title: String?
        let iconPath: String?
        let backgroundHex = key.backgroundColorHex
        if case .pageIndicator = key.action {
            if let info = config.currentPagePositionInScene {
                title = "\(info.position + 1)/\(info.count)"
            } else {
                title = nil
            }
            iconPath = nil
        } else if case .sleepGuard = key.action {
            // 暗夜仪表(§6.33):专用渲染,状态即视觉(忽略底色/标题配置)。
            // 翻转时播锁扣开合过渡(unknown/unauthorized 涉及的切换直接换帧)
            let visual = currentSleepGuardVisual()
            if let image = SleepGuardTileRenderer.image(state: visual) {
                let previous = lastSleepGuardVisual
                lastSleepGuardVisual = visual
                setKeyImage(index: index, image: image)
                if let previous, previous != visual, visual != .unauthorized, previous != .unauthorized,
                   let frames = SleepGuardTileRenderer.transitionFrames(from: previous, to: visual) {
                    tileFX.play(index: index, frames: frames, final: image)
                }
                return
            }
            // 渲染失败回落常规路径(理论上不可达)
            title = nil
            iconPath = nil
        } else {
            title = key.title.isEmpty ? nil : key.title
            iconPath = key.iconPath
        }
        // 插件键且有实例:syncKey 顶部的 redrawInstanceIfPresent 已出插件帧,
        // 再渲瓷贴兜底帧就是白做一整趟「渲染+JPEG+HID」后立刻被盖掉;无实例(插件缺失)
        // 才需要瓷贴帧提示「插件未安装」
        if case .plugin = key.action, pluginHost.hasInstance(at: index) {
            return
        }
        guard let image = IconRenderer.render(
            size: StreamDock293S.keySize(column: column),
            backgroundColorHex: backgroundHex,
            title: title,
            iconPath: iconPath,
            symbolName: key.action?.defaultIconSymbol
        ) else {
            appendLog("键面渲染失败(r\(row) c\(column),检查颜色/图标)")
            return
        }
        setKeyImage(index: index, image: image)
        // 插件实例在则按当前态重渲(多状态动作上屏即显 manifest 默认图,盖过上方瓷砖)
        if case .plugin = key.action {
            pluginHost.redrawInstanceIfPresent(at: index)
            pressPulse.detach(ifIndex: index) // 插件键帧由插件推,脉冲基帧不适用
            picMode.detach(ifIndex: index)
            return
        }
        // 按压脉冲键:常规渲染产物即基帧,挂给脉冲动画器(编辑/换页后重挂 = 基帧更新)
        if key.animation == .pressPulse {
            pressPulse.attach(index: index, base: image)
        } else {
            pressPulse.detach(ifIndex: index)
        }
    }

    /// 统计槽位对账:扫描当前页 15 键里的 .stat 动作,喂给节拍器当渲染清单。
    /// 统计键自 2026-11-01 起随配置走(不再是保留槽):放哪哪显示,清除即消失,换页自动挂卸。
    private func syncStatSlots() {
        let scene = config.currentSceneIndex
        let page = config.currentPageIndex
        guard config.config.scenes.indices.contains(scene),
              config.config.scenes[scene].pages.indices.contains(page) else {
            statTiles.setSlots([])
            return
        }
        var slots: [(index: Int, kind: StatKind)] = []
        for (index, key) in config.config.scenes[scene].pages[page].keys.enumerated()
        where ReservedSlots.slot(at: index) == nil {
            if case .stat(let kind) = key.action {
                slots.append((index, kind))
            }
        }
        statTiles.setSlots(slots)
    }

    /// 编辑器实时预览:动效键的静息帧(已预旋转,KeycapView 会转回正立)
    func animationPreviewFrame(for key: KeyConfig) -> CGImage? {
        if case .keyboardHeatmap = key.action {
            return heatmap.previewImage(size: StreamDock293S.keySize(column: 0))
        }
        if case .sleepGuard = key.action {
            return SleepGuardTileRenderer.image(state: currentSleepGuardVisual())
        }
        if case .mediaKey(let kind) = key.action {
            return MediaTileRenderer.image(kind: kind)
        }
        if key.animation == .picModeToggle {
            let mode = PicModeTileRenderer.Mode(stateFile: PicModeTileRenderer.currentStateFile())
            return PicModeTileRenderer.image(mode: mode)
        }
        guard key.animation == .monitorInput else { return nil }
        return monitorInput.previewImage(size: StreamDock293S.keySize(column: 0))
    }

    /// 睡眠锁当前视觉态(nil = 启动后尚未读到,显示 …)
    private func currentSleepGuardVisual() -> SleepGuardTileRenderer.VisualState {
        if sleepGuardUnauthorized { return .unauthorized }
        switch sleepGuardEnabled {
        case true: return .on
        case false: return .off
        case nil: return .unknown
        }
    }

    /// 键面图像统一入口:设备写一份、对应单键镜像槽存一份(网格 KeycapView 据此与设备同源)
    private func setKeyImage(index: Int, image: CGImage) {
        if keyImageSlots.indices.contains(index) {
            keyImageSlots[index].image = image
        }
        device.drawKey(row: index / StreamDock293S.columns,
                       column: index % StreamDock293S.columns, image: image)
    }

    // MARK: - 玻璃对位校准

    /// 当前玻璃对位补偿(视觉坐标,正 = 右/上;0,0 = 不补偿)
    var glassOffset: GlassOffset { config.glassOffset }

    /// 设备玻璃窗口相对 framebuffer 的偏心补偿(视觉坐标,正 = 右/上;zoom 百分比)。
    /// 实时预览区拖动即时生效:落盘配置 → 下发给设备 → 按新参数重发缓存帧(UI 镜像不变)。
    private var glassCommitTask: Task<Void, Never>?

    /// 玻璃对位补偿:内存即时生效;重渲(80ms)与落盘(再 700ms)防抖合并——
    /// 校准条每格都「15 键 JPEG 重渲 + 全量写盘」曾造成主线程卡顿
    func setGlassOffset(_ offset: GlassOffset) {
        guard offset != config.glassOffset else { return }
        config.setGlassOffsetInMemory(offset)
        device.setGlassOffset(x: offset.x, y: offset.y, zoom: offset.zoom)
        glassCommitTask?.cancel()
        glassCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.device.redrawCachedKeys()
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.config.save()
        }
    }

    // MARK: - 亮度（转发到亮度域协调器）

    /// 拖动滑杆调用:更新内存与设备(实时反馈),不落盘;跟随模式下手动调节自动退出跟随
    func setBrightness(_ percent: Int, userInitiated: Bool = true) {
        brightness.setBrightness(percent, userInitiated: userInitiated)
    }

    /// 拖动结束调用:一次性落盘,避免滑杆每帧写配置文件
    func commitBrightness() {
        brightness.commitBrightness()
    }

    // MARK: - 亮度跟随系统

    var followSystemBrightness: Bool {
        brightness.followSystemBrightness
    }

    /// 开关「亮度跟随 MacBook」:开启后每 1.5s 镜像内建屏亮度(环境光自动调节即随之生效)。
    /// 与自动熄屏互斥:开启跟随即关闭自动熄屏(夜间变暗由跟随的 0% 涂黑承担)
    func setFollowSystemBrightness(_ on: Bool) {
        brightness.setFollowSystemBrightness(on)
    }

    /// ⋯菜单「自动熄屏」:与亮度跟随互斥——开启自动熄屏将关闭亮度跟随
    func setAutoScreenOffMinutes(_ minutes: Int) {
        brightness.setAutoScreenOffMinutes(minutes)
    }

    /// 「滑杆 0% 时键面涂黑」开关;关闭时若正处涂黑态立即按当前真实状态恢复
    func setSliderZeroBlacksKeys(_ on: Bool) {
        brightness.setSliderZeroBlacksKeys(on)
    }

    // MARK: - 官方 app 冲突(策略见 SystemIntegration)

    func refreshOfficialAppFlag() {
        officialAppRunning = system.isOfficialAppRunning
    }

    /// 请求退出官方 StreamDock.app
    func quitOfficialApp() {
        system.terminateOfficialApp()
    }

    // MARK: - 登录项

    /// 是否已注册开机自启(裸二进制运行时注册会失败,打包成 .app 后有效)
    var isLaunchAtLoginEnabled: Bool {
        system.isLaunchAtLoginEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        system.setLaunchAtLogin(enabled)
    }

    // MARK: - 私有

    /// 官方 app 启动/退出都会改变 runningApplications,监听工作区通知保持标志新鲜
    private func observeWorkspaceApplications() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            workspaceObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshOfficialAppFlag()
                    self?.sceneRouter.autoSwitchPageForFrontmostApp()
                }
            })
        }
        // Mac 睡眠唤醒:睡眠期间心跳中断,设备多半已自重启进待机;若 USB 未重枚举,
        // attach 校准不会触发,须主动重校准恢复键面(设备若真重枚举了,守卫让位给 attach 路径)
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.device.recalibrateAfterSystemWake()
            }
        })
    }

    /// 日志唯一入口:落 stdout + oslog + 环形缓存(实现见 LogRing)
    private func appendLog(_ line: String) {
        logs.append(line)
    }
}
