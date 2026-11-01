import SwiftUI

/// 运行日志面板:诊断信息的唯一可见出口。
///
/// 背景:各子系统(插件宿主/显示器 DDC/统计/配置)的失败一直有记录,
/// 但记录终点是没人渲染的 LogRing——用户只看到「键没反应」,不知道为什么。
/// 本面板把日志环尾部翻出来,新日志在上;内容与 `log stream --predicate
/// 'subsystem == "opendeck"'` 同源(环只是 oslog 的内存镜像)。
struct LogSheet: View {
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss

    /// 环是尾部最新;面板按用户习惯「新在上」展示
    private var lines: [String] {
        appModel.recentLogs.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    HStack {
                        Text("最近 \(lines.count) 条(新在上);同源可 log stream 取证")
                        Spacer()
                        Button("复制全部") {
                            let payload = lines.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(payload, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 460)
    }
}
