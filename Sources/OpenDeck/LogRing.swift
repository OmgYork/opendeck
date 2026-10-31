import Foundation
import os

/// 日志环:诊断日志的唯一落点。
///
/// 三个通道同时写(拆分前就在 AppModel 里,行为不变):
/// - stdout:swift run 直跑时可观察(以行缓冲模式输出)
/// - oslog:`log stream` / `log show --info` 可取证(.app 后台运行时唯一可用通道)
/// - 内存环:状态栏只显示尾部一屏,环形保留 12 条
///
/// 不做 @Observable:环内内容当前只有状态栏读取,且读取点不在 SwiftUI body 的
/// 观察路径上(拆分前它也只是 AppModel 的一个普通属性)。
@MainActor
final class LogRing {
    /// 环容量:一屏即可,超出丢最早
    private static let capacity = 12

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
