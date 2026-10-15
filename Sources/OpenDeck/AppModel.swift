import AppKit
import Darwin
import IOKit
import Observation
import os
import ServiceManagement
import StreamDockKit

/// 应用级模型:粘合驱动层(DeviceController)与配置层(ConfigStore)。
/// 职责:按键事件 → 动作分发、键面渲染上屏、亮度同步、官方 app 冲突检测。
@MainActor
@Observable
final class AppModel {
    /// 官方 StreamDock.app 的 bundle id(HID 设备独占,双方共存会互抢导致图标闪烁)
    static let officialBundleID = "com.mirabox.streamdock"

    let device = DeviceController()
    let config = ConfigStore()
    let pluginHost = PluginHostModel()

    /// 官方 app 是否正在运行(驱动编辑器顶部的冲突警示条)
    private(set) var officialAppRunning = false
    /// 当前物理按下的键(index 集合)——UI 键帽同步凹陷,验证「按哪颗亮哪颗」
    private(set) var pressedKeyIndices: Set<Int> = []
    /// 最近设备日志(尾部最新),仅供状态栏展示,环形保留一屏即可
    private(set) var recentLogs: [String] = []

    private var started = false
    /// 观察者与进程同生命周期,无需移除;保留 token 仅为可测试性
    private var workspaceObservers: [NSObjectProtocol] = []

    var latestLog: String? { recentLogs.last }

    // MARK: - 生命周期

    /// 幂等启动:检测官方 app、接管按键回调、同步已存亮度、开始热插拔监控。
    func start() {
        guard !started else { return }
        started = true

        refreshOfficialAppFlag()
        observeWorkspaceApplications()

        pluginHost.hooks.draw = { [weak self] index, image in
            guard let self else { return }
            self.device.drawKey(row: index / StreamDock293S.columns,
                                column: index % StreamDock293S.columns, image: image)
        }
        pluginHost.hooks.backgroundColor = { [weak self] index in
            self?.config.keyConfig(at: index).backgroundColorHex ?? "#3B4252"
        }
        pluginHost.hooks.open = { url in NSWorkspace.shared.open(url) }
        pluginHost.hooks.log = { [weak self] line in
            self?.appendLog(line)
        }
        pluginHost.start()

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
            self.lastDeviceActivityAt = Date()
            // 熄屏待机:任意按下沿唤醒,该次按压不产生动作
            if self.device.isScreenOff {
                if event.phase == .down { self.device.wakeFromScreenOff() }
                return
            }
            // 键面纯黑(亮度跟随 0% 态):按下沿暂时与内屏解耦——点亮键面至最近有效亮度,
            // 动作照常触发;内屏亮度下次变化时镜像自动重新关联(涂黑或跟随新值)
            if event.phase == .down, self.device.keysBlacked {
                self.device.setKeysBlacked(false)
                self.setBrightness(self.lastNonZeroMirroredBrightness, userInitiated: false)
                self.armPeekReDarken()
            }
            let action = self.config.keyConfig(at: index).action
            // 插件动作:按下/抬起两沿都转发(协议要求),不走原生动作执行器
            if case .plugin = action {
                self.pluginHost.handleKey(index: index, phase: event.phase)
                return
            }
            // 其余动作只在按下沿触发,抬起沿不重复执行
            guard event.phase == .down, let action else { return }
            // 设备控制动作(页面/亮度/熄屏)本地消化,不经 ActionRunner
            if self.handleDeviceAction(action) { return }
            Task { await ActionRunner.run(action) }
        }

        // 先同步亮度再 start():设备连接校准时控制器会以已存值设置背光
        device.setBrightness(config.config.brightness)
        device.start()
        // 配置了跟随系统亮度则启动轮询(设备连上后 1.5s 内完成首次镜像)
        if config.followSystemBrightness {
            startFollowingBrightness()
        }
        // 亮度跟随与自动熄屏互斥(2026-10-15):旧配置两者同开时,启动即归一化关闭自动熄屏
        if config.followSystemBrightness, config.autoScreenOffMinutes > 0 {
            config.autoScreenOffMinutes = 0
            appendLog("亮度跟随开启中,自动熄屏已关闭(两者互斥)")
        }
        startScreenOffWatchdog()
    }

    /// 应用退出时收割插件进程并释放设备,挂到 applicationWillTerminate
    func handleAppQuit() {
        pluginHost.shutdown()
        device.shutdown()
    }

    // MARK: - 场景与页面(两级)

    /// 切换到指定场景;同场景重复切换无副作用
    func switchScene(to id: UUID) {
        guard let index = config.indexOfScene(id: id), index != config.config.currentSceneIndex else { return }
        config.setCurrentSceneIndex(index)
        applyPageToDevice()
    }

    /// 循环切换场景(上一场景/下一场景;落到目标场景第一页)
    func switchScene(offset: Int) {
        guard let target = config.targetSceneIndex(offset: offset) else { return }
        config.setCurrentSceneIndex(target)
        applyPageToDevice()
    }

    /// 切换到指定页(跨场景按 Page.id 定位;圆点点击直达用)
    func switchPage(to id: UUID) {
        guard let location = config.pageLocation(id: id) else { return }
        guard location.sceneIndex != config.config.currentSceneIndex
                || location.pageIndex != config.config.currentPageIndex else { return }
        config.setCurrentSceneIndex(location.sceneIndex)
        config.currentPageIndex = location.pageIndex
        applyPageToDevice()
    }

    /// 场景内循环翻页(上一页/下一页)
    func switchPage(offset: Int) {
        guard let target = config.targetPageIndex(offset: offset) else { return }
        config.currentPageIndex = target
        applyPageToDevice()
    }

    func addScene() {
        let id = config.addScene()
        switchScene(to: id)
    }

    func duplicateScene(id: UUID) {
        _ = config.duplicateScene(id: id)
    }

    /// 删除场景;若删的是当前场景(索引被回退),设备需重画新当前场景
    func deleteScene(id: UUID) {
        config.deleteScene(id: id)
        applyPageToDevice()
    }

    /// 当前场景加一页(圆点 +1)并切到新页
    func addPageToCurrentScene() {
        let sceneIndex = config.config.currentSceneIndex
        guard config.addPage(toSceneIndex: sceneIndex) != nil else { return }
        config.currentPageIndex = config.currentScene.pages.count - 1
        applyPageToDevice()
    }

    /// 给指定场景加一页(圆点 +1)并切到该场景新页
    func addPage(toScene id: UUID) {
        guard let sceneIndex = config.indexOfScene(id: id),
              config.addPage(toSceneIndex: sceneIndex) != nil
        else { return }
        switchScene(to: id)
        config.currentPageIndex = config.currentScene.pages.count - 1
        applyPageToDevice()
    }

    /// 删除当前场景内的一页(每场景至少保留 1 页)
    func deletePageInCurrentScene(at pageIndex: Int) {
        config.deletePage(sceneIndex: config.config.currentSceneIndex, pageIndex: pageIndex)
        applyPageToDevice()
    }

    // MARK: - 场景联动(前台应用自动切换场景)

    /// 编辑器窗口是否可见:官方语义为「应用窗口关闭时」才做前台切换,配置期间不打扰
    var editorWindowVisible = true

    /// 前台应用变化:优先切到绑定了该应用的场景;无绑定且设了默认场景则回默认场景
    func autoSwitchPageForFrontmostApp() {
        guard !editorWindowVisible, !device.isScreenOff else { return }
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        Self.oslog.debug("联动评估:前台=\(bundleID, privacy: .public)")
        let currentSceneID = config.currentSceneID
        if let bound = config.sceneBoundToApp(bundleID) {
            if bound.id != currentSceneID, let id = bound.id {
                appendLog("场景联动:「\(bundleID)」→ 场景「\(bound.name)」")
                switchScene(to: id)
            }
            return
        }
        if let defaultID = config.config.defaultSceneID,
           defaultID != currentSceneID,
           config.indexOfScene(id: defaultID) != nil {
            appendLog("场景联动:「\(bundleID)」无绑定 → 默认场景")
            switchScene(to: defaultID)
        }
    }

    /// 已安装应用清单(场景联动下拉用;/Applications + /System/Applications,按名称排序)
    nonisolated static func installedApps() -> [(bundleID: String, name: String)] {
        var directories = FileManager.default.urls(for: .applicationDirectory, in: .systemDomainMask)
        directories.append(URL(fileURLWithPath: "/System/Applications"))
        var seen = Set<String>()
        var apps: [(bundleID: String, name: String)] = []
        for directory in directories {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                      bundleID != "com.opendeck.app", !seen.contains(bundleID)
                else { continue }
                seen.insert(bundleID)
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append((bundleID, name))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - 设备控制动作

    /// 页面/亮度/熄屏类动作:纯本地状态操作。返回 true 表示已消化
    private func handleDeviceAction(_ action: KeyAction) -> Bool {
        switch action {
        case .previousPage: switchPage(offset: -1)
        case .nextPage: switchPage(offset: 1)
        case .previousScene: switchScene(offset: -1)
        case .nextScene: switchScene(offset: 1)
        case .gotoPage(let pageID):
            // 兼容旧配置的动作:跨场景按 Page.id 定位
            if let location = config.pageLocation(id: pageID) {
                config.setCurrentSceneIndex(location.sceneIndex)
                config.currentPageIndex = location.pageIndex
                applyPageToDevice()
            }
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
        let key = config.keyConfig(at: index)
        pluginHost.syncKey(at: index, action: key.action)
        // 页面指示键:标题动态显示 "N/M",随页面切换自动刷新
        let title: String?
        let iconPath: String?
        if case .pageIndicator = key.action {
            if let info = config.currentPagePositionInScene {
                title = "\(info.position + 1)/\(info.count)"
            } else {
                title = nil
            }
            iconPath = nil
        } else {
            title = key.title.isEmpty ? nil : key.title
            iconPath = key.iconPath
        }
        guard let image = IconRenderer.render(
            size: StreamDock293S.keySize(column: column),
            backgroundColorHex: key.backgroundColorHex,
            title: title,
            iconPath: iconPath
        ) else {
            appendLog("键面渲染失败(r\(row) c\(column),检查颜色/图标)")
            return
        }
        device.drawKey(row: row, column: column, image: image)
    }

    // MARK: - 亮度

    /// 拖动滑杆调用:更新内存与设备(实时反馈),不落盘;跟随模式下手动调节自动退出跟随
    func setBrightness(_ percent: Int, userInitiated: Bool = true) {
        if userInitiated, config.followSystemBrightness {
            setFollowSystemBrightness(false)
        }
        let clamped = max(0, min(100, percent))
        config.brightness = clamped
        device.setBrightness(clamped)
        // 「滑杆 0% 时键面涂黑」(可选):手动拉到 0 视同键面熄灭;拖离 0 立即恢复
        guard userInitiated else { return }
        if clamped == 0, config.sliderZeroBlacksKeys, !device.isScreenOff {
            device.setKeysBlacked(true)
        } else if clamped > 0, device.keysBlacked, !device.isScreenOff {
            device.setKeysBlacked(false)
        }
    }

    /// 拖动结束调用:一次性落盘,避免滑杆每帧写配置文件
    func commitBrightness() {
        config.save()
    }

    // MARK: - 亮度跟随系统

    var followSystemBrightness: Bool {
        config.followSystemBrightness
    }

    /// 开关「亮度跟随 MacBook」:开启后每 1.5s 镜像内建屏亮度(环境光自动调节即随之生效)。
    /// 与自动熄屏互斥:开启跟随即关闭自动熄屏(夜间变暗由跟随的 0% 涂黑承担)
    func setFollowSystemBrightness(_ on: Bool) {
        config.followSystemBrightness = on
        if on, config.autoScreenOffMinutes > 0 {
            config.autoScreenOffMinutes = 0
            appendLog("亮度跟随已开启,自动熄屏已关闭(两者互斥)")
        }
        on ? startFollowingBrightness() : stopFollowingBrightness()
    }

    /// ⋯菜单「自动熄屏」:与亮度跟随互斥——开启自动熄屏将关闭亮度跟随
    func setAutoScreenOffMinutes(_ minutes: Int) {
        config.autoScreenOffMinutes = minutes
        if minutes > 0, config.followSystemBrightness {
            appendLog("自动熄屏已开启,亮度跟随已关闭(两者互斥)")
            setFollowSystemBrightness(false)
        }
    }

    /// 「滑杆 0% 时键面涂黑」开关;关闭时若正处涂黑态立即按当前真实状态恢复
    func setSliderZeroBlacksKeys(_ on: Bool) {
        config.sliderZeroBlacksKeys = on
        if config.followSystemBrightness {
            lastMirroredBrightness = -1 // 强制下个轮询重同步(内屏 0 时维持涂黑,非 0 恢复)
            mirrorSystemBrightnessOnce()
        } else if device.keysBlacked, !device.isScreenOff {
            device.setKeysBlacked(false)
            setBrightness(config.brightness, userInitiated: false)
        }
    }

    // MARK: - 自动熄屏(空闲看门狗)

    /// 最近一次设备按键时间(自动熄屏的空闲时钟;唤醒按键也会重置)
    private var lastDeviceActivityAt = Date()
    private var screenOffWatchdogTask: Task<Void, Never>?

    private func startScreenOffWatchdog() {
        guard screenOffWatchdogTask == nil else { return }
        screenOffWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                self.autoScreenOffCheck()
            }
        }
    }

    private func autoScreenOffCheck() {
        let minutes = config.autoScreenOffMinutes
        guard minutes > 0, device.state == .running, !device.isScreenOff else { return }
        guard Date().timeIntervalSince(lastDeviceActivityAt) >= TimeInterval(minutes * 60) else { return }
        device.screenOff()
        appendLog("设备空闲超过 \(minutes) 分钟,已自动熄屏")
    }

    private var followTask: Task<Void, Never>?
    /// 上次镜像到设备的百分比:轮询读值便宜,但 USB 写没必要重复
    private var lastMirroredBrightness = -1
    /// 最近一次非 0 的镜像亮度:「0% 涂黑后按键点亮」的暂态亮度(与内屏暂时解耦)
    private var lastNonZeroMirroredBrightness = 80
    /// 内建屏亮度读取失败的去重标志(失败态每 1.5s 才轮一次,不去重会刷屏)
    private var lastBrightnessReadFailed = false

    private func startFollowingBrightness() {
        followTask?.cancel()
        lastMirroredBrightness = -1 // 重新进入跟随:强制首次下发
        lastBrightnessReadFailed = false
        appendLog("亮度跟随:开始(1.5s 轮询)")
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.mirrorSystemBrightnessOnce()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        mirrorSystemBrightnessOnce()
    }

    private func stopFollowingBrightness() {
        followTask?.cancel()
        followTask = nil
        appendLog("亮度跟随:停止")
    }

    private func mirrorSystemBrightnessOnce() {
        guard config.followSystemBrightness, device.state == .running, !device.isScreenOff else { return }
        guard let percent = Self.systemBrightnessPercent() else {
            if !lastBrightnessReadFailed {
                lastBrightnessReadFailed = true
                appendLog("亮度跟随:内建屏亮度读取失败(持续静默重试)")
            }
            return
        }
        lastBrightnessReadFailed = false
        guard abs(percent - lastMirroredBrightness) >= 1 else { return }
        lastMirroredBrightness = percent
        appendLog("亮度跟随:MacBook \(percent)% → 设备")
        if percent > 0 { lastNonZeroMirroredBrightness = percent }
        if percent == 0 {
            // 内屏全黑 → 键面涂黑(设备背光 0 只是「最暗」档,非黑屏;黑像素 + 最暗背光才是真黑)
            setBrightness(0, userInitiated: false)
            device.setKeysBlacked(true)
        } else {
            device.setKeysBlacked(false)
            setBrightness(percent, userInitiated: false)
        }
    }

    /// 「0% 涂黑后按键点亮」的 15s 无操作重涂黑任务:期间每次设备按键都会重新计时
    private var peekReDarkenTask: Task<Void, Never>?

    /// 按键点亮涂黑键面后武装重涂黑定时
    private func armPeekReDarken() {
        peekReDarkenTask?.cancel()
        peekReDarkenTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            self.reDarkenIfIdleInDark()
        }
    }

    /// 点亮 15s 后复查:暗源仍为 0(内屏 0 / 滑杆 0 涂黑态)→ 重新涂黑;内屏已变亮则跟随接管,勿动
    private func reDarkenIfIdleInDark() {
        guard !device.isScreenOff, !device.keysBlacked else { return }
        guard lastMirroredBrightness <= 0 else { return } // 跟随中且内屏非 0:键面应保持可见
        let sliderDark = config.sliderZeroBlacksKeys && config.brightness == 0
        guard lastMirroredBrightness == 0 || sliderDark else { return }
        setBrightness(0, userInitiated: false)
        device.setKeysBlacked(true)
        appendLog("亮度跟随:15s 无操作,重新涂黑")
    }

    /// 内建屏亮度(0–100)。读取链:DisplayServices(私有,macOS 26 实测唯一有效,
    /// 外接屏返回不支持——本就只镜像内屏)→ IOKit IODisplayConnect 旧路径(其他机型兜底)。
    /// (CoreDisplay_GetUserBrightness 在 macOS 26 恒返 1.0 假值,已弃用——假值比失败更有害)
    private static func systemBrightnessPercent() -> Int? {
        if let percent = displayServicesBrightnessPercent() { return percent }
        return legacyDisplayBrightnessPercent()
    }

    private static let displayServicesGetBrightness: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let sym = dlsym(ds, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    private static func displayServicesBrightnessPercent() -> Int? {
        guard let get = displayServicesGetBrightness, let displayID = builtInDisplayID() else { return nil }
        var level: Float = -1
        guard get(displayID, &level) == 0, level.isFinite, level >= 0, level <= 1.001 else { return nil }
        return max(0, min(100, Int((level * 100).rounded())))
    }

    private static func builtInDisplayID() -> UInt32? {
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
            if CGDisplayIsBuiltin(id) != 0 { return id }
        }
        return nil
    }

    private static func legacyDisplayBrightnessPercent() -> Int? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            var level: Float = -1
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &level) == KERN_SUCCESS, level >= 0 {
                return max(0, min(100, Int((level * 100).rounded())))
            }
        }
        return nil
    }

    // MARK: - 官方 app 冲突

    func refreshOfficialAppFlag() {
        officialAppRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.officialBundleID
        }
    }

    /// 请求退出官方 StreamDock.app
    func quitOfficialApp() {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.officialBundleID }?
            .terminate()
    }

    // MARK: - 登录项

    /// 是否已注册开机自启(裸二进制运行时注册会失败,打包成 .app 后有效)
    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appendLog("登录项设置失败:\(error.localizedDescription)")
        }
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
                    self?.autoSwitchPageForFrontmostApp()
                }
            })
        }
    }

    private func appendLog(_ line: String) {
        print("📜 \(line)") // 镜像到 stdout:swift run 直跑时可观察(swift run 以 stdout 缓冲行模式输出)
        Self.oslog.info("\(line, privacy: .public)") // 镜像到 oslog:.app 后台运行时可用 log stream 取证
        recentLogs.append(line)
        if recentLogs.count > 12 {
            recentLogs.removeFirst(recentLogs.count - 12)
        }
    }

    private static let oslog = Logger(subsystem: "opendeck", category: "device")
}
