import StreamDockKit
import SwiftUI

/// 布局调参面板:四个实时滑杆直接驱动真实亮度胶囊,所见即所得。
/// 拖动只改内存,「完成/保存」落盘;「右端同心」一键设为轨道与胶囊同心的右边距。
struct LayoutTuningSheet: View {
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss

    private var layout: Binding<LayoutParams> {
        Binding(
            get: { appModel.config.layout },
            set: { appModel.config.layout = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("亮度胶囊布局(实时预览)") {
                    LabeledContent("胶囊左边距") {
                        slider(layout.lead, in: 4...40)
                    }
                    LabeledContent("太阳↔滑杆间距") {
                        slider(layout.gap, in: 0...30)
                    }
                    LabeledContent("滑杆槽宽") {
                        slider(layout.slot, in: 80...220)
                    }
                    LabeledContent("胶囊右边距") {
                        HStack {
                            slider(layout.trail, in: 4...40)
                            Button("右端同心") {
                                layout.wrappedValue.trail = LayoutParams.concentricTrail
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Section {
                    HStack {
                        Button("还原默认") {
                            layout.wrappedValue = .defaultValue
                        }
                        Spacer()
                        Button("完成") {
                            appModel.config.save()
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
    }

    private func slider(_ value: Binding<CGFloat>, in range: ClosedRange<CGFloat>) -> some View {
        Slider(value: value, in: range)
            .controlSize(.small)
    }
}
