import AppKit
import Observation
import StreamDockKit

/// 应用级模型:粘合驱动层(DeviceController)与配置层(ConfigStore)。
/// 职责:按键事件 → 动作分发、键面渲染上屏、亮度同步、官方 app 冲突检测。
@MainActor
@Observable
final class AppModel {
    /// 官方 StreamDock.app 的 bundle id(定义在 SystemIntegration)
    static let officialBundleID = SystemIntegration.officialBundleID

    let device = DeviceController()
    // MARK: - 固定保留槽(策略见 ReservedSlots)

    /// 保留槽类型(EditorView 以「== nil」判断用户槽，故保留同名 typealias)
    typealias ReservedSlot = ReservedSlots.Slot

    /// 该格是否为保留槽
    static func reservedSlot(at index: Int) -> ReservedSlot? {
        ReservedSlots.slot(at: index)
    }

    /// Stats 槽位(索引)
    static let statSlots: [(index: Int, kind: StatKind)] = ReservedSlots.statSlots

    /// 键位最终生效配置:保留槽强制保留瓷贴,其余读用户配置
    static func resolvedKeyConfig(at index: Int, config: ConfigStore) -> KeyConfig {
        ReservedSlots.keyConfig(at: index, config: config)
    }

    let config = ConfigStore()
    let pluginHost = PluginHostModel()
    /// 内建动效键面:显示器输入源(Mac ↔ PC)。全局只有一路输入状态,故单实例。
    let monitorInput = MonitorInputAnimator()
    /// 内建读数键面:键盘热力图(KeyAnalyze)。同样是单实例,只服务当前页那一颗。
    let heatmap = KeyboardHeatmapAnimator()
    /// Stats 瓷贴节拍器(CPU/GPU/温度,三颗保留槽整帧刷新)
    let statTiles = StatTileAnimator()
    /// 亮度域:背光、内屏亮度读取、跟随轮询、0% 涂黑与回涂黑、空闲熄屏看门狗
    let brightness: BrightnessCoordinator
    /// 场景/页面路由域:两级导航、场景与页面增删、按前台应用联动
    let sceneRouter: SceneRouter
    /// 系统集成域:官方 app 冲突检测、登录项
    let system = SystemIntegration()
    /// 日志环:stdout + oslog + 内存环
    let logs = LogRing()

    /// animator 回调统一在 init 挂接(接入约定):编辑器 WindowGroup 的 `.onAppear`
    /// 会先于 `.task { start() }` 调 `applyPageToDevice()`,若等到 start() 才接 hook,
    /// 首次 attach 的帧会被丢掉。三个 animator 同一时机,不在此处区分。
    init() {
        // 先构造全部协调器(捕获 self 的前提是存储属性已全部初始化),再统一挂钩子
        brightness = BrightnessCoordinator(device: device, config: config)
        sceneRouter = SceneRouter(config: config, device: device)
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
    /// 「缺授权」提示每会话只弹一次:反复按键不该反复打断
    private var didWarnSleepGuard = false

    private var started = false
    /// 观察者与进程同生命周期,无需移除;保留 token 仅为可测试性
    private var workspaceObservers: [NSObjectProtocol] = []
    /// App Nap 断言:菜单栏 app 长期无窗口时会被整进程挂起,插件 webview 的
    /// 定时器/轮询随之冻结(HTML 家族无界面可见性,尤甚)。设备心跳与插件宿主
    /// 是本 app 的存在意义,进程常驻即业务,断言与进程同生命周期。
    private var activityToken: NSObjectProtocol?

    var latestLog: String? { logs.latest }

    // MARK: - 生命周期

    /// 幂等启动:检测官方 app、接管按键回调、同步已存亮度、开始热插拔监控。
    func start() {
        guard !started else { return }
        started = true

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "OpenDeck:设备心跳与插件宿主常驻"
        )
        // Stats 集成:瓷贴节拍器接管采样与整帧刷新(设备 + UI 镜像同源)
        statTiles.start(slots: Self.statSlots)

        refreshOfficialAppFlag()
        observeWorkspaceApplications()

        pluginHost.hooks.draw = { [weak self] index, image in
            guard let self else { return }
            self.setKeyImage(index: index, image: image)
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
        // 动效键面(animator)的帧回调已在 init 挂接,这里只启动各自的节拍

        device.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        device.onKeyEvent = { [weak self] event in
            guard let self else { return }
            let index = event.row * StreamDock293S.columns + event.column
            self.appendLog("按键 r\(event.row)c\(event.column) \(event.phase == .down ? "按下" : "抬起") 熄屏态=\(self.device.isScreenOff)")
            // @Observable 靠属性赋值触发观测,集合原地增删不生效,须整体重赋
            self.pressedKeyIndices = event.phase == .down
                ? self.pressedKeyIndices.union([index])
                : self.pressedKeyIndices.subtracting([index])
            self.brightness.noteDeviceActivity()
            // 熄屏待机:任意按下沿唤醒,该次按压不产生动作
            if self.device.isScreenOff {
                if event.phase == .down { self.device.wakeFromScreenOff() }
                return
            }
            // 键面纯黑(亮度跟随 0% 态):按下沿暂时与内屏解耦——点亮键面至最近有效亮度,
            // 动作照常触发;内屏亮度下次变化时镜像自动重新关联(涂黑或跟随新值)
            if event.phase == .down, self.device.keysBlacked {
                self.device.setKeysBlacked(false)
                self.setBrightness(self.brightness.lastNonZeroMirroredPercent, userInitiated: false)
                self.brightness.armPeekReDarken()
            }
            // 固定导航键(位置 14/15)的动作是解析后强制的,配置原文在这两格恒空,
            // 直接读配置会让按键事件无动作(2026-10-18 用户反馈按压无反应)
            let key = Self.resolvedKeyConfig(at: index, config: config)
            let action = key.action
            // 插件动作:按下/抬起两沿都转发(协议要求),不走原生动作执行器
            if case .plugin = action {
                self.pluginHost.handleKey(index: index, phase: event.phase)
                return
            }
            // 热键 = 键盘按键:按下沿 keyDown、抬起沿 keyUp(按住槽位 = 按住该键;单按修饰键如右⌘也走这里)
            if case .hotkey(let keyCode, let modifiers) = action {
                Task { await ActionRunner.runHotkey(keyCode: keyCode, modifiers: modifiers, down: event.phase == .down) }
                return
            }
            // 其余动作只在按下沿触发,抬起沿不重复执行
            guard event.phase == .down, let action else { return }
            // 热力图键:读数与状态都在 animator 里,按下只转发给它自己的入口
            if case .keyboardHeatmap = action {
                self.heatmap.handlePress()
                return
            }
            // 合盖休眠锁:要跑 sudo 并回读,独立异步路径(不阻塞按键回调,也不进 ActionRunner)
            if case .sleepGuard = action {
                Task { await self.toggleSleepGuard(at: index) }
                return
            }
            // 设备控制动作(页面/亮度/熄屏)本地消化,不经 ActionRunner
            if self.handleDeviceAction(action) { return }
            // 动效键面:先起动画,再照常执行动作(乐观展示,状态文件随后对账)
            if key.animation == .monitorInput {
                self.monitorInput.handlePress()
            }
            Task { await ActionRunner.run(action) }
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

    // MARK: - 设备控制动作

    /// 翻转合盖休眠锁:执行 → 回读 → 更新缓存并重画该键。
    /// 失败不静默:键面回落到真实状态,状态栏留日志,并提示一次授权问题。
    private func toggleSleepGuard(at index: Int) async {
        switch await SleepGuard.toggle() {
        case .success(let enabled):
            sleepGuardEnabled = enabled
            appendLog("合盖休眠锁 → \(enabled ? "开(合盖不睡)" : "关(合盖休眠)")")
            applyKey(at: index)
        case .failure(let error):
            sleepGuardEnabled = await SleepGuard.currentState()
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "合盖休眠锁不可用"
        alert.informativeText = """
            \(message)

            需要一次性安装免密规则(只放行 pmset disablesleep 的 0/1 两个取值):
            \(SleepGuard.sudoersPath)
            """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 页面/亮度/熄屏类动作:纯本地状态操作。返回 true 表示已消化
    private func handleDeviceAction(_ action: KeyAction) -> Bool {
        switch action {
        case .previousPage: switchPage(offset: -1)
        case .nextPage: switchPage(offset: 1)
        case .previousScene: switchScene(offset: -1)
        case .nextScene: switchScene(offset: 1)
        case .gotoPage(let pageID):
            // 兼容旧配置的动作:跨场景按 Page.id 定位
            sceneRouter.gotoLegacyPage(pageID)
        case .screenOff: device.screenOff()
        case .pageIndicator: break // 纯显示键,按下无操作
        default: return false
        }
        return true
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
        pluginHost.syncKey(at: index, action: key.action)
        // Stats 槽:整帧由瓷贴节拍器覆盖,这里先上占位帧(采样值或 "--")
        if case .stat(let kind) = Self.reservedSlot(at: index) {
            if let image = statTiles.placeholderTile(kind: kind) {
                setKeyImage(index: index, image: image)
            }
            return
        }
        // 热力图键:整帧由读数键的 animator 驱动,同样跳过常规渲染
        if case .keyboardHeatmap = key.action {
            heatmap.attach(index: index, size: StreamDock293S.keySize(column: column))
            return
        }
        heatmap.detach(ifIndex: index)
        // 内建动效键:整帧由动画驱动,跳过常规「底色 + 底图 + 标题」渲染
        if key.animation == .monitorInput {
            monitorInput.attach(index: index, size: StreamDock293S.keySize(column: column))
            return
        }
        monitorInput.detach(ifIndex: index) // 同页其它键/换页后的旧动效键
        // 页面指示键:标题动态显示 "N/M",随页面切换自动刷新
        let title: String?
        let iconPath: String?
        var backgroundHex = key.backgroundColorHex
        if case .pageIndicator = key.action {
            if let info = config.currentPagePositionInScene {
                title = "\(info.position + 1)/\(info.count)"
            } else {
                title = nil
            }
            iconPath = nil
        } else if case .sleepGuard = key.action {
            // 合盖休眠锁:键面即状态。绿=已禁止合盖休眠,灰=正常休眠,蓝灰=尚未读到
            switch sleepGuardEnabled {
            case true:
                title = "睡眠锁 ON"
                backgroundHex = "#2E7D32"
            case false:
                title = "睡眠锁 OFF"
                backgroundHex = "#3B4252"
            case nil:
                title = "睡眠锁 ⋯"
                backgroundHex = "#4C566A"
            }
            iconPath = nil
        } else {
            title = key.title.isEmpty ? nil : key.title
            iconPath = key.iconPath
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
        }
    }

    /// 编辑器实时预览:动效键的静息帧(已预旋转,KeycapView 会转回正立)
    func animationPreviewFrame(for key: KeyConfig) -> CGImage? {
        if case .keyboardHeatmap = key.action {
            return heatmap.previewImage(size: StreamDock293S.keySize(column: 0))
        }
        guard key.animation == .monitorInput else { return nil }
        return monitorInput.previewImage(size: StreamDock293S.keySize(column: 0))
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
    func setGlassOffset(_ offset: GlassOffset) {
        guard offset != config.glassOffset else { return }
        config.glassOffset = offset
        device.setGlassOffset(x: offset.x, y: offset.y, zoom: offset.zoom)
        device.redrawCachedKeys()
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
