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
