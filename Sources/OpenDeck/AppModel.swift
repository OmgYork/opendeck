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
            // 只在按下沿触发动作,抬起沿不重复执行
            guard event.phase == .down, let action = self.config.keyConfig(at: index).action else { return }
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

    /// 应用退出时释放设备(发送断开命令并停止监控),挂到 applicationWillTerminate
    func handleAppQuit() {
        device.shutdown()
    }

    // MARK: - 键面上屏

    /// 当前页 18 键全部渲染并下发
    func applyPageToDevice() {
        for index in 0..<(StreamDock293S.rows * StreamDock293S.columns) {
            applyKey(at: index)
        }
    }

    /// 单键重画:编辑保存后即时上屏
    func applyKey(at index: Int) {
        let row = index / StreamDock293S.columns
        let column = index % StreamDock293S.columns
        let key = config.keyConfig(at: index)
        guard let image = IconRenderer.render(
            size: StreamDock293S.keySize(column: column),
            backgroundColorHex: key.backgroundColorHex,
            title: key.title.isEmpty ? nil : key.title,
            iconPath: key.iconPath
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
        guard config.followSystemBrightness, device.state == .running,
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
        ]
        for name in names {
            workspaceObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshOfficialAppFlag() }
            })
        }
    }

    private func appendLog(_ line: String) {
        recentLogs.append(line)
        if recentLogs.count > 12 {
            recentLogs.removeFirst(recentLogs.count - 12)
        }
    }
}
