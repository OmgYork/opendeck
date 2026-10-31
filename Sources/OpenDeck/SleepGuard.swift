import Foundation
import os

// MARK: - 合盖休眠锁（pmset -a disablesleep）
//
// 为什么必须 root：clamshell 睡眠由 PM 硬件路径决定，用户态 assertion
// （caffeinate / IOPMAssertion 的 PreventUserIdleSystemSleep）只挡 idle sleep，
// 合盖照样睡。系统里唯一入口是 `pmset -a disablesleep`，且只接受 root。
// SMJobBless 特权助手在本机走不通：OpenDeck 是 ad-hoc 签名，无 Developer ID。
//
// 授权模型：`/etc/sudoers.d/pmset-disablesleep` 精确放行这一条命令的两个取值，
// 其余 sudo 权限不变。所有写入一律带 `sudo -n`（non-interactive）：没有规则时
// 立刻失败退出，而不是在无 tty 的子进程里等密码 —— 那样按键反馈会被吞掉最多 60 秒。
//
// 写入后必回读校验：命令返回 0 不等于生效（DDC 那一轮的教训）。

nonisolated enum SleepGuard {
    static let logger = Logger(subsystem: "opendeck", category: "sleepguard")

    static let pmsetPath = "/usr/bin/pmset"
    static let sudoPath = "/usr/bin/sudo"
    static let sudoersPath = "/etc/sudoers.d/pmset-disablesleep"

    enum Failure: LocalizedError {
        case readFailed(String)
        case authorizationMissing
        case writeFailed(exitCode: Int32, stderr: String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .readFailed(let detail):
                return "读取合盖休眠状态失败:\(detail)"
            case .authorizationMissing:
                return "缺少免密授权(\(SleepGuard.sudoersPath) 未安装或规则不匹配)"
            case .writeFailed(let code, let stderr):
                return stderr.isEmpty
                    ? "pmset 写入失败(退出码 \(code))"
                    : "pmset 写入失败(退出码 \(code)):\(stderr)"
            case .verificationFailed:
                return "pmset 已返回成功,但回读状态与预期不一致"
            }
        }
    }

    // MARK: 读

    /// 当前态：true = 已禁止合盖休眠（SleepDisabled=1）；nil = 读不到。
    /// `pmset -g` 无需 root，输出形如：
    ///     System-wide power settings:
    ///      SleepDisabled		0
    @concurrent
    static func currentState() async -> Bool? {
        let result = run(pmsetPath, ["-g"])
        guard result.status == 0 else { return nil }
        for line in result.out.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            return fields[1] == "1"
        }
        return nil
    }

    // MARK: 写

    /// 翻转当前态并回读校验，返回生效后的新状态。
    @concurrent
    static func toggle() async -> Result<Bool, Failure> {
        guard let enabled = await currentState() else {
            return .failure(.readFailed("`pmset -g` 输出里没有 SleepDisabled 行"))
        }
        return await setEnabled(!enabled)
    }

    /// 写成指定值并回读校验。
    @concurrent
    static func setEnabled(_ enabled: Bool) async -> Result<Bool, Failure> {
        let value = enabled ? "1" : "0"
        let result = run(sudoPath, ["-n", pmsetPath, "-a", "disablesleep", value])
        guard result.status == 0 else {
            // sudo 的拒绝文案随版本/语言变化，认几个稳定片段即可
            let stderr = result.err.lowercased()
            if stderr.contains("password is required")
                || stderr.contains("a terminal is required")
                || stderr.contains("not allowed") {
                logger.error("sleepGuard: sudoers 规则缺失或未匹配")
                return .failure(.authorizationMissing)
            }
            return .failure(.writeFailed(exitCode: result.status,
                                         stderr: result.err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        // 回读校验：pmset 应当同步生效，留几次重试兜住驱动层抖动
        for attempt in 0..<5 {
            if let actual = await currentState(), actual == enabled {
                logger.info("sleepGuard → \(value, privacy: .public) (verified)")
                return .success(actual)
            }
            if attempt < 4 {
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        logger.error("sleepGuard → \(value, privacy: .public) 写入返回成功但回读不一致")
        return .failure(.verificationFailed)
    }

    // MARK: 子进程

    /// 同步跑一个短命命令：stdout/stderr 全量捕获，退出码透传。
    /// 先 drain 管道再 wait，避免输出塞满缓冲后父子互相等死。
    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", "无法启动 \(executable):\(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }
}
