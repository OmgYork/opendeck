import AppKit
import Observation
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
            // 只在按下沿触发动作,抬起沿不重复执行
            guard let self, event.phase == .down else { return }
            let index = event.row * StreamDock293S.columns + event.column
            guard let action = self.config.keyConfig(at: index).action else { return }
            Task { await ActionRunner.run(action) }
        }

        // 先同步亮度再 start():设备连接校准时控制器会以已存值设置背光
        device.setBrightness(config.config.brightness)
        device.start()
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

    /// 拖动中调用:更新内存与设备(实时反馈),不落盘
    func setBrightness(_ percent: Int) {
        let clamped = max(0, min(100, percent))
        config.brightness = clamped
        device.setBrightness(clamped)
    }

    /// 拖动结束调用:一次性落盘,避免滑杆每帧写配置文件
    func commitBrightness() {
        config.save()
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
