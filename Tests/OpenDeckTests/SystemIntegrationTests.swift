import Foundation
import Testing
@testable import OpenDeck

/// 启动方式三态(§6.37):LaunchAgent plist 形状、模式切换决策矩阵、构建指纹格式。
/// IO 面(bootstrap/bootout/SMAppService)不进测试,决策与形状在此钉死。
@MainActor
@Suite("启动方式与构建指纹")
struct SystemIntegrationTests {
    @Test("agent plist:Label/RunAtLoad/KeepAlive.SuccessfulExit=false/Throttle")
    func agentPlistShape() throws {
        let plist = SystemIntegration.agentPlist(executablePath: "/Applications/OpenDeck.app/Contents/MacOS/OpenDeck")
        #expect(plist["Label"] as? String == "com.opendeck.app")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["ProgramArguments"] as? [String])?.first == "/Applications/OpenDeck.app/Contents/MacOS/OpenDeck")
        let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
        #expect(keepAlive["SuccessfulExit"] as? Bool == false, "正常退出不重启,崩溃/被杀才重启")
        #expect(plist["ThrottleInterval"] as? Int == 5, "崩溃循环限速")
        let env = try #require(plist["EnvironmentVariables"] as? [String: String])
        #expect(env["OPDECK_LAUNCHED_BY_AGENT"] == "1", "RunAtLoad 撞单实例锁时静默退出的标记")
    }

    /// 切换决策矩阵:互斥不变量(登录项/agent 至多一个)的每条边
    @Test("切换决策矩阵:换路径必先清旧,同路径零操作")
    func launchStepsMatrix() {
        typealias Steps = (installAgent: Bool, removeAgent: Bool, setLogin: Bool?)
        func steps(_ c: LaunchMode, _ t: LaunchMode) -> Steps {
            SystemIntegration.resolveLaunchSteps(currentMode: c, target: t)
        }
        // 同模式:零操作
        for mode in LaunchMode.allCases {
            let s = steps(mode, mode)
            #expect(!s.installAgent && !s.removeAgent && s.setLogin == nil)
        }
        // → 登录项:清 agent + 注册登录项
        let toLogin = steps(.crashAutoRestart, .loginItem)
        #expect(!toLogin.installAgent && toLogin.removeAgent && toLogin.setLogin == true)
        // → 自愈:装 agent + 清登录项(RunAtLoad 覆盖开机)
        let toAgent = steps(.loginItem, .crashAutoRestart)
        #expect(toAgent.installAgent && !toAgent.removeAgent && toAgent.setLogin == false)
        // → 关:各自清各自的
        let offFromLogin = steps(.loginItem, .off)
        #expect(!offFromLogin.installAgent && !offFromLogin.removeAgent && offFromLogin.setLogin == false)
        let offFromAgent = steps(.crashAutoRestart, .off)
        #expect(!offFromAgent.installAgent && offFromAgent.removeAgent && offFromAgent.setLogin == nil)
    }

    @Test("构建指纹:缺键兜底 ?,完整键 commit·state time")
    func fingerprintFormat() {
        #expect(AppModel.buildFingerprint(info: [:]) == "?·? ?")
        let full = AppModel.buildFingerprint(info: [
            "OpenDeckBuildCommit": "b8f6af3",
            "OpenDeckBuildState": "dirty",
            "OpenDeckBuildTime": "2026-11-05T23:03:17Z",
        ])
        #expect(full == "b8f6af3·dirty 2026-11-05T23:03:17Z")
    }
}
