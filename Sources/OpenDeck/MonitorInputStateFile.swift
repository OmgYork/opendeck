import Foundation

/// LG 显示器「当前输入源」状态文件。
///
/// 这个路径是三方的唯一事实源:切源后写入者、键面读数、toggle 方向判定必须同一份,
/// 否则会出现「设备显示 mac、实际在 pc」的矛盾。取值 `mac` / `pc`(带换行)。
/// 与 `~/bin/lg-toggle.sh` 共用同一文件,两条路径才不会打架。
///
/// 放在独立文件而不是某个渲染器/DDC 类型里:它是文件系统契约,不该由渲染器持有
/// (渲染器要能单独编译成预览工具),也不该埋在 DDC 实现细节里。
enum MonitorInputStateFile {
    /// `~/.cache/lg_input`(展开后的绝对路径,运行时解析一次)
    nonisolated static let path = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/lg_input")
}

/// LG 显示器「当前图像模式」状态文件(~/.cache/lg_pic_mode)。
/// 取值 `game` / `read`(OpenDeck 写入;与 picModeToggle 动效键配套,VCP 0x15 两档)。
/// 独立文件的缘由同 lg_input:文件系统契约不归渲染器/DDC 持有。
enum MonitorPicModeStateFile {
    nonisolated static let path = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/lg_pic_mode")

    /// 原子写入(tmp+rename,与 lg_input 同规)
    static func write(_ value: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? value.write(to: url, atomically: true, encoding: .utf8)
    }

    static func read() -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
