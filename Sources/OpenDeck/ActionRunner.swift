import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

// MARK: - 错误模型

/// 动作执行错误:面向用户的中文描述。一律记日志;
/// 仅「需要用户操作才能解决」的错误(如辅助功能未授权)额外弹窗。
enum ActionError: LocalizedError {
    case appLaunchFailed(path: String, underlying: any Error)
    case invalidURL(String)
    case processLaunchFailed(command: String, underlying: any Error)
    case processFailed(command: String, exitCode: Int32, stderr: String)
    case processTimedOut(command: String, timeoutSeconds: Int64)
    case accessibilityPermissionRequired
    case invalidHotkeyCode(Int)
    case unknownMediaKey(String)
    case eventCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .appLaunchFailed(let path, let underlying):
            return "无法打开应用“\(path)”:\(underlying.localizedDescription)"
        case .invalidURL(let urlString):
            return "无效的 URL:\(urlString)"
        case .processLaunchFailed(let command, let underlying):
            return "无法启动\(command):\(underlying.localizedDescription)"
        case .processFailed(let command, let exitCode, let stderr):
            if stderr.isEmpty {
                return "\(command)执行失败(退出码 \(exitCode))"
            }
            return "\(command)执行失败(退出码 \(exitCode)):\(stderr)"
        case .processTimedOut(let command, let timeoutSeconds):
            return "\(command)超过 \(timeoutSeconds) 秒未完成,已强制终止"
        case .accessibilityPermissionRequired:
            return "发送快捷键需要辅助功能权限"
        case .invalidHotkeyCode(let keyCode):
            return "无效的按键码:\(keyCode)"
        case .unknownMediaKey(let name):
            return "未知的媒体键:\(name)"
        case .eventCreationFailed(let what):
            return "无法构造系统事件:\(what)"
        }
    }
}

// MARK: - 后台执行器

/// 重活全部放在并发池:显式 nonisolated + @concurrent,
/// 无论模块默认隔离设置为何,都不会占用主线程。
/// 函数只返回结构化错误、不做上报,由主线程的 ActionRunner 统一记日志/弹窗。
nonisolated enum ActionExecutor {
    private static let logger = Logger(subsystem: "opendeck", category: "action")
    /// 子进程超时(秒):构建/网络类脚本给足时间,又不至于永久占死
    private static let processTimeoutSeconds: Int64 = 60
    /// SIGTERM 后宽限(秒):仍不退则 SIGKILL 兜底(脚本可能捕获或忽略 TERM)
    private static let terminateGraceSeconds: Int64 = 5

    /// 修饰键名 → CGEventFlags(KeyAction.hotkey 的 modifiers 约定)
    private static let modifierFlagsByName: [String: CGEventFlags] = [
        "command": .maskCommand,
        "option": .maskAlternate,
        "control": .maskControl,
        "shift": .maskShift,
    ]

    /// 媒体键名 → NX 系统键码(与 IOKit hidsystem 的 NX_KEYTYPE 常量一致)
    static let mediaKeyCodes: [String: Int] = [
        "playPause": 16,
        "next": 17,
        "previous": 18,
        "volumeUp": 0,
        "volumeDown": 1,
        "mute": 7,
    ]

    /// 运行外部进程:继承环境变量、捕获 stderr、超时终止。
    /// 成功返回 nil,失败返回结构化错误交主线程上报。
    @concurrent
    static func execute(executablePath: String, arguments: [String], label: String) async -> ActionError? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // 不设置 environment 即完整继承当前进程环境
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // stdout 无人消费,接 /dev/null,防止子进程写满管道缓冲后与父进程互相等死
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .processLaunchFailed(command: label, underlying: error)
        }

        // 挂起式轮询等待(不占线程);到点先 SIGTERM,宽限后 SIGKILL 保证必然退出
        let clock = ContinuousClock()
        let start = clock.now
        var didRequestTermination = false
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                return nil // 调用方已放弃,不再上报
            }
            let elapsed = start.duration(to: .now)
            if !didRequestTermination, elapsed >= .seconds(processTimeoutSeconds) {
                didRequestTermination = true
                process.terminate()
            } else if didRequestTermination, elapsed >= .seconds(processTimeoutSeconds + terminateGraceSeconds) {
                // SIGKILL 兜底:Process 只封装了 terminate(SIGTERM)
                kill(process.processIdentifier, SIGKILL)
                break
            }
            try? await Task.sleep(for: .milliseconds(100)) // 动作级精度足够,挂起休眠几乎零开销
        }

        // 进程已退出(管道写端已关),此刻读取不会阻塞
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if didRequestTermination {
            return .processTimedOut(command: label, timeoutSeconds: processTimeoutSeconds)
        }
        if process.terminationStatus != 0 {
            return .processFailed(command: label, exitCode: process.terminationStatus, stderr: stderr)
        }
        if !stderr.isEmpty {
            // 成功但带 stderr:多为无害警告(osascript 提示等),留日志即可
            logger.notice("\(label) stderr:\(stderr, privacy: .public)")
        }
        return nil
    }

    /// 合成全局快捷键的按下+抬起(CGEvent 注入,效果等同真实键盘输入)
    @concurrent
    static func postHotkey(keyCode: Int, modifiers: [String]) async -> ActionError? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
        else {
            return .eventCreationFailed("快捷键(keyCode=\(keyCode))")
        }
        let flags = modifierFlags(for: modifiers)
        down.flags = flags
        up.flags = flags
        // cghidEventTap:HID 层注入,前台任意 App 均可收到
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return nil
    }

    private static func modifierFlags(for names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            guard let flag = modifierFlagsByName[name.lowercased()] else {
                // 未知修饰键降级跳过而非失败:配置手误不应让整颗键失灵
                logger.warning("忽略未知修饰键“\(name, privacy: .public)”")
                continue
            }
            flags.insert(flag)
        }
        return flags
    }
}

// MARK: - 动作入口

/// 键动作统一入口:UI 与按键事件只调 run(_:),调度与上报细节收敛在这里。
@MainActor
enum ActionRunner {
    private static let logger = Logger(subsystem: "opendeck", category: "action")

    static func run(_ action: KeyAction) async {
        switch action {
        case .openApp(let path):
            await openApp(at: path)
        case .openURL(let urlString):
            openURL(urlString)
        case .runShortcut(let name):
            if let error = await ActionExecutor.execute(
                executablePath: "/usr/bin/shortcuts",
                arguments: ["run", name],
                label: "快捷指令“\(name)”"
            ) { report(error) }
        case .shellScript(let script):
            if let error = await ActionExecutor.execute(
                executablePath: "/bin/zsh",
                arguments: ["-c", script],
                label: "Shell 脚本"
            ) { report(error) }
        case .appleScript(let script):
            if let error = await ActionExecutor.execute(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", script],
                label: "AppleScript"
            ) { report(error) }
        case .hotkey(let keyCode, let modifiers):
            await runHotkey(keyCode: keyCode, modifiers: modifiers)
        case .mediaKey(let name):
            postMediaKey(named: name)
        }
    }

    // MARK: 私有

    private static func openApp(at path: String) async {
        do {
            try await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: .init()
            )
        } catch {
            report(.appLaunchFailed(path: path, underlying: error))
        }
    }

    private static func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            report(.invalidURL(urlString))
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func runHotkey(keyCode: Int, modifiers: [String]) async {
        // 注入全局键盘事件前必须确认辅助功能授权;未授权时系统会静默丢弃事件
        guard AXIsProcessTrusted() else {
            report(.accessibilityPermissionRequired)
            return
        }
        // 虚拟键码合法范围兜底:防手改配置传负数/超大值,在 UInt32 转换时崩溃
        guard (0...255).contains(keyCode) else {
            report(.invalidHotkeyCode(keyCode))
            return
        }
        if let error = await ActionExecutor.postHotkey(keyCode: keyCode, modifiers: modifiers) {
            report(error)
        }
    }

    private static func postMediaKey(named name: String) {
        guard let keyCode = ActionExecutor.mediaKeyCodes[name] else {
            report(.unknownMediaKey(name))
            return
        }
        // NSEvent 是 AppKit 主线程类型:构造→提取 CGEvent→post 全程在主线程完成,
        // 总开销微秒级;搬去后台反而要为非 Sendable 的 NSEvent 做隔离跳转
        let downPayload = (keyCode << 16) | (0xA << 8) // 0xA:系统定义媒体事件标记
        for payload in [downPayload, downPayload | 1] { // 末位 |1:抬起
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8, // 媒体键(NX_SUBTYPE_...系统定义事件,参数为裸 short)
                data1: payload,
                data2: -1
            ), let cgEvent = event.cgEvent else {
                report(.eventCreationFailed("媒体键“\(name)”"))
                return
            }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    /// 上报策略:一律记日志;只有需要用户处理的错误才弹窗打断
    private static func report(_ error: ActionError) {
        logger.error("\(error.localizedDescription, privacy: .public)")
        if case .accessibilityPermissionRequired = error {
            presentAccessibilityAlert()
        }
    }

    private static func presentAccessibilityAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "发送快捷键动作需要“辅助功能”授权。请在「系统设置 > 隐私与安全性 > 辅助功能」中勾选 OpenDeck,然后重试。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
              let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
