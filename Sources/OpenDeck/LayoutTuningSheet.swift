import StreamDockKit
import SwiftUI

/// 布局调参面板:四个实时滑杆直接驱动真实亮度胶囊,所见即所得。
/// 拖动只改内存(实时预览),「完成」落盘;非完成路径关闭则还原到盘上值。
/// 此前每个滑杆刻度都全量原子写盘(与头注释自相矛盾),已改为草稿模式。
/// 「右端同心」一键设为轨道与胶囊同心的右边距。
struct LayoutTuningSheet: View {
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss

    /// 草稿:拖动期间只进内存(ConfigStore.setLayoutInMemory),「完成」经 setter 落盘
    @State private var draft: LayoutParams
    /// 正常关闭(完成)置 true;否则 onDisappear 还原到盘上值
    @State private var committed = false

    init(appModel: AppModel) {
        self.appModel = appModel
        _draft = State(initialValue: appModel.config.layout)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("亮度胶囊布局(实时预览)") {
                    LabeledContent("胶囊左边距") {
                        slider($draft.lead, in: 4...40)
                    }
                    LabeledContent("太阳↔滑杆间距") {
                        slider($draft.gap, in: -8...30)
                    }
                    LabeledContent("滑杆槽宽") {
                        slider($draft.slot, in: 80...220)
                    }
                    LabeledContent("胶囊右边距") {
                        HStack {
                            slider($draft.trail, in: 4...40)
                            Button("右端同心") {
                                draft.trail = LayoutParams.concentricTrail
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Section {
                    HStack {
                        Button("还原默认") {
                            draft = .defaultValue
                        }
                        Spacer()
                        Button("完成") {
                            appModel.config.layout = draft
                            committed = true
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460)
        .onChange(of: draft) { _, newValue in
            appModel.config.setLayoutInMemory(newValue) // 实时预览:只进内存
        }
        .onDisappear {
            // 非完成路径关闭(拖出/Esc):还原到盘上值,胶囊同步复原
            if !committed {
                appModel.config.setLayoutInMemory(appModel.config.layout)
            }
        }
    }

    private func slider(_ value: Binding<CGFloat>, in range: ClosedRange<CGFloat>) -> some View {
        Slider(value: value, in: range)
            .controlSize(.small)
    }
}
