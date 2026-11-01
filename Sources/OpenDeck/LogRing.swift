import Foundation
import os

/// 日志环:诊断日志的唯一落点。
///
/// 三个通道同时写(拆分前就在 AppModel 里,行为不变):
/// - stdout:swift run 直跑时可观察(以行缓冲模式输出)
/// - oslog:`log stream` / `log show --info` 可取证(.app 后台运行时唯一可用通道)
/// - 内存环:「运行日志」面板展示尾部 50 条
///
/// 做 @Observable:「运行日志」面板打开时实时尾随新日志。
@MainActor
@Observable
final class LogRing {
    /// 环容量:诊断面板一屏可读的量级,超出丢最早
    private static let capacity = 50

    /// 最近日志(尾部最新)
    private(set) var recentLogs: [String] = []

    var latest: String? {
        recentLogs.last
    }

    /// 与 AppModel 拆分前同参的 Logger:输出通道(subsystem/category)保持不变
    static let oslog = Logger(subsystem: "opendeck", category: "device")

    func append(_ line: String) {
        print("📜 \(line)") // 镜像到 stdout:swift run 直跑时可观察
        Self.oslog.info("\(line, privacy: .public)") // 镜像到 oslog:后台运行时可用 log stream 取证
        recentLogs.append(line)
        if recentLogs.count > Self.capacity {
            recentLogs.removeFirst(recentLogs.count - Self.capacity)
        }
    }
}
