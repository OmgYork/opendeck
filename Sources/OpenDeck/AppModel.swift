import AppKit
import IOKit
import Observation
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
            // @Observable 靠属性赋值触发观测,集合原地增删不生效,须整体重赋
            self.pressedKeyIndices = event.phase == .down
                ? self.pressedKeyIndices.union([index])
                : self.pressedKeyIndices.subtracting([index])
            // 熄屏待机:任意按下沿唤醒,该次按压不产生动作
            if self.device.isScreenOff {
                if event.phase == .down { self.device.wakeFromScreenOff() }
                return
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
    }

    /// 应用退出时收割插件进程并释放设备,挂到 applicationWillTerminate
    func handleAppQuit() {
        pluginHost.shutdown()
        device.shutdown()
    }

    // MARK: - 页面

    /// 切换到指定页(按 id);同页重复切换无副作用
    func switchPage(to id: UUID) {
        guard let index = config.indexOfPage(id: id), index != config.config.currentPageIndex else { return }
        config.setCurrentPageIndex(index)
        applyPageToDevice()
    }

    /// 循环切换页(上一页/下一页;第 1 页的上一页 = 末页)
    func switchPage(offset: Int) {
        let count = config.pageCount
        guard count > 1 else { return }
        let target = ((config.config.currentPageIndex + offset) % count + count) % count
        guard let id = config.config.pages[target].id else { return }
        switchPage(to: id)
    }

    func addPage() {
        let id = config.addPage()
        switchPage(to: id)
    }

    func duplicatePage(id: UUID) {
        _ = config.duplicatePage(id: id)
    }

    // MARK: - 场景联动(前台应用自动切换页面)

    /// 编辑器窗口是否可见:官方语义为「应用窗口关闭时」才做前台切换,配置期间不打扰
    var editorWindowVisible = true

    /// 前台应用变化:优先切到绑定了该应用的页;无绑定且设了默认页则回默认页
    func autoSwitchPageForFrontmostApp() {
        guard !editorWindowVisible, !device.isScreenOff else { return }
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        let currentPageID = config.currentPage.id
        if let bound = config.pageBoundToApp(bundleID) {
            if bound.id != currentPageID, let id = bound.id {
                switchPage(to: id)
            }
            return
        }
        if let defaultID = config.config.defaultPageID,
           defaultID != currentPageID,
           config.indexOfPage(id: defaultID) != nil {
            switchPage(to: defaultID)
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

    /// 删除页;若删的是当前页(索引被回退),设备需重画新当前页
    func deletePage(id: UUID) {
        config.deletePage(id: id)
        applyPageToDevice()
    }

    // MARK: - 设备控制动作

    /// 页面/亮度/熄屏类动作:纯本地状态操作。返回 true 表示已消化
    private func handleDeviceAction(_ action: KeyAction) -> Bool {
        switch action {
        case .previousPage: switchPage(offset: -1)
        case .nextPage: switchPage(offset: 1)
        case .gotoPage(let pageID): switchPage(to: pageID)
        case .brightnessUp: setBrightness(config.brightness + 10); commitBrightness()
        case .brightnessDown: setBrightness(config.brightness - 10); commitBrightness()
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
            title = "\(config.config.currentPageIndex + 1)/\(config.pageCount)"
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
    }

    /// 拖动结束调用:一次性落盘,避免滑杆每帧写配置文件
    func commitBrightness() {
        config.save()
    }

    // MARK: - 亮度跟随系统

    var followSystemBrightness: Bool {
        config.followSystemBrightness
    }

    /// 开关「亮度跟随 MacBook」:开启后每 1.5s 镜像内建屏亮度(环境光自动调节即随之生效)
    func setFollowSystemBrightness(_ on: Bool) {
        config.followSystemBrightness = on
        on ? startFollowingBrightness() : stopFollowingBrightness()
    }

    private var followTask: Task<Void, Never>?
    /// 上次镜像到设备的百分比:轮询读值便宜,但 USB 写没必要重复
    private var lastMirroredBrightness = -1

    private func startFollowingBrightness() {
        followTask?.cancel()
        lastMirroredBrightness = -1 // 重新进入跟随:强制首次下发
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
    }

    private func mirrorSystemBrightnessOnce() {
        guard config.followSystemBrightness, device.state == .running, !device.isScreenOff,
              let percent = Self.systemBrightnessPercent() else { return }
        guard abs(percent - lastMirroredBrightness) >= 1 else { return }
        lastMirroredBrightness = percent
        setBrightness(percent, userInitiated: false)
    }

    /// 内建屏亮度(IODisplayConnect,0.0–1.0)→ 百分比;外接屏/读取失败返回 nil
    private static func systemBrightnessPercent() -> Int? {
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
        recentLogs.append(line)
        if recentLogs.count > 12 {
            recentLogs.removeFirst(recentLogs.count - 12)
        }
    }
}
