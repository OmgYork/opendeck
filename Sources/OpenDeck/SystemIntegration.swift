import AppKit
import Darwin
import ServiceManagement

/// 系统集成域:与本机其它「抢设备/抢启动」的东西打交道。
///
/// - 官方 StreamDock.app 冲突:双方都要独占 HID 设备,共存会互抢导致键面图标闪烁,
///   所以启动与工作区通知时都要能判定它是否在跑,并支持一键请它退出。
/// - 登录项(SMAppService):裸二进制运行时注册会失败,打包成 .app 后有效。
///
/// 纯搬移:bundle id、判据(遍历 runningApplications)、`.terminate()`、
/// `SMAppService.mainApp` 的注册/注销与失败日志文案都与拆分前一致。
@MainActor
final class SystemIntegration {
    /// 官方 StreamDock.app 的 bundle id(HID 设备独占,双方共存会互抢导致图标闪烁)
    static let officialBundleID = "com.mirabox.streamdock"

    /// 诊断日志钩子(与其它子系统一致:在持有者 init 里挂接)
    var onLog: ((String) -> Void)?

    /// 官方 app 是否正在运行
    var isOfficialAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.officialBundleID
        }
    }

    /// 请求退出官方 StreamDock.app
    func terminateOfficialApp() {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.officialBundleID }?
            .terminate()
    }

    /// 是否已注册开机自启
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
            onLog?("登录项设置失败:\(error.localizedDescription)")
        }
    }
}

// MARK: - 启动方式(登录项 / 崩溃自愈 LaunchAgent,§6.37)

/// 启动方式三态。互斥不变量:登录项(SMAppService)与崩溃自愈(LaunchAgent)至多一个
/// 生效——双路径并存会让每次开机弹出「OpenDeck 已在运行」的单实例对话框
enum LaunchMode: String, CaseIterable {
    case off
    case loginItem       // SMAppService 登录项:开机启动,崩溃不重启
    case crashAutoRestart // LaunchAgent:RunAtLoad 覆盖开机 + KeepAlive 崩溃自愈

    var label: String {
        switch self {
        case .off: return "不自动启动"
        case .loginItem: return "登录时启动"
        case .crashAutoRestart: return "登录 + 崩溃自愈"
        }
    }
}

extension SystemIntegration {
    static let agentLabel = "com.opendeck.app"

    /// LaunchAgent plist 内容(纯函数,可测)。KeepAlive.SuccessfulExit=false:
    /// 崩溃/被杀(非零退出)→ launchd 自动重启;正常退出(0)→ 保持退出
    static func agentPlist(executablePath: String) -> [String: Any] {
        [
            "Label": agentLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5, // 崩溃循环限速:最快 5s 重启一次
            // 标记来源:agent 的 RunAtLoad 会在「安装时 app 已在跑」时拉起第二实例,
            // 实例锁让第二实例**静默**退出(无标记则弹「已在运行」对话框,装一次弹一次)
            "EnvironmentVariables": ["OPDECK_LAUNCHED_BY_AGENT": "1"],
        ]
    }

    /// 目标模式 → 执行步骤的决策(纯函数,可测)。调用方按序执行 IO
    static func resolveLaunchSteps(currentMode: LaunchMode, target: LaunchMode) -> (installAgent: Bool, removeAgent: Bool, setLogin: Bool?) {
        switch (currentMode, target) {
        case (.off, .off), (.loginItem, .loginItem), (.crashAutoRestart, .crashAutoRestart):
            return (false, false, nil) // 无变化
        case (.off, .loginItem), (.crashAutoRestart, .loginItem):
            return (false, true, true) // 清 agent(若有)+ 注册登录项
        case (.off, .crashAutoRestart), (.loginItem, .crashAutoRestart):
            return (true, false, false) // 装 agent + 清登录项(RunAtLoad 已覆盖开机)
        case (.loginItem, .off), (.crashAutoRestart, .off):
            return (false, currentMode == .crashAutoRestart, currentMode == .loginItem ? false : nil)
        }
    }

    /// 当前生效的启动方式(agent 文件存在 = 自愈态;否则查 SMAppService)
    var launchMode: LaunchMode {
        if isCrashAutoRestartEnabled { return .crashAutoRestart }
        return isLaunchAtLoginEnabled ? .loginItem : .off
    }

    var isCrashAutoRestartEnabled: Bool {
        FileManager.default.fileExists(atPath: Self.agentPlistURL.path)
    }

    /// 运行形态是否支持自愈(.app;swift run 直跑的裸二进制 plist 指向不稳定)
    var isAppBundleForm: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// 切换启动方式(互斥:先清旧路径再装新路径)。失败经 onLog,不静默
    func setLaunchMode(_ target: LaunchMode) {
        guard isAppBundleForm || target == .off else {
            onLog?("崩溃自愈仅支持 .app 形态(当前为开发直跑),已忽略")
            return
        }
        let current = launchMode
        guard current != target else { return }
        let steps = Self.resolveLaunchSteps(currentMode: current, target: target)

        if steps.removeAgent { removeAgentFile() }
        if let setLogin = steps.setLogin { setLaunchAtLogin(setLogin) }
        if steps.installAgent { installAgent() }
        onLog?("启动方式 → \(target.label)")
    }

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private func installAgent() {
        let fileManager = FileManager.default
        guard let executable = Bundle.main.executableURL else {
            onLog?("崩溃自愈安装失败:无法定位可执行文件")
            return
        }
        do {
            try fileManager.createDirectory(at: Self.agentPlistURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let plist = Self.agentPlist(executablePath: executable.path)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: Self.agentPlistURL, options: .atomic)
            // 立即加载(RunAtLoad 触发首跑;若已在跑会被 InstanceLock 弹窗拦截的概率极低:
            // 本函数只在面板切换时调用,当前实例就在跑——bootstrap 的首跑会撞锁退出,无碍)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(getuid())", Self.agentPlistURL.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                // 已加载(重复安装)是常态失败,静默;其余记日志
                onLog?("崩溃自愈:agent 已写入(bootstrap 返回 \(process.terminationStatus),若为已加载属正常)")
            }
        } catch {
            onLog?("崩溃自愈安装失败:\(error.localizedDescription)")
        }
    }

    private func removeAgentFile() {
        // 先 bootout 卸载(未加载时失败无害),再删文件
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(Self.agentLabel)"]
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: Self.agentPlistURL)
    }
}
