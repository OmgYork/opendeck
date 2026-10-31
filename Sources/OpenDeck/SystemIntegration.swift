import AppKit
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
