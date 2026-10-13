import AppKit
import StreamDockKit
import SwiftUI

@main
struct OpenDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("OpenDeck") {
            EditorView(appModel: appModel)
                .onAppear { appDelegate.appModel = appModel }
        }
        .defaultSize(width: 840, height: 720)

        // 用窗口样式而非菜单样式:菜单样式的 NSMenu 承载不了亮度 Slider
        MenuBarExtra("OpenDeck", systemImage: "rectangle.grid.3x2") {
            MenuBarPanel(appModel: appModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 退出清理挂这里:applicationWillTerminate 是 SwiftUI 生命周期之外唯一可靠的退出时机
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        appModel?.handleAppQuit()
    }
}

/// 菜单栏浮窗:紧凑的状态面板,材质与主窗口一致
private struct MenuBarPanel: View {
    let appModel: AppModel

    @State private var brightness: Double = 0

    private var connected: Bool { appModel.device.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行:品牌 + 连接状态
            HStack(spacing: 7) {
                Text("OpenDeck")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(connected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                    .shadow(color: connected ? .green.opacity(0.6) : .clear, radius: 3)
                Text(connected ? "已连接" : "未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appModel.officialAppRunning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("官方 StreamDock 正在运行")
                        .font(.caption)
                    Spacer()
                    Button("退出它") {
                        appModel.quitOfficialApp()
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: brightness < 15 ? "sun.min" : "sun.max.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
                Slider(value: $brightness, in: 0...100) { editing in
                    if !editing { appModel.commitBrightness() }
                }
                Text("\(Int(brightness))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            .onChange(of: brightness) { _, newValue in
                appModel.setBrightness(Int(newValue))
            }
            .onChange(of: appModel.config.brightness) { _, newValue in
                // 与主窗口滑杆互相同步;同值守卫避免回写循环
                if Int(brightness) != newValue {
                    brightness = Double(newValue)
                }
            }

            Button {
                appModel.applyPageToDevice()
            } label: {
                Label("重新应用到设备", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Divider()

            Button {
                // 经 applicationWillTerminate 触发设备清理,不走直接 exit
                NSApp.terminate(nil)
            } label: {
                Label("退出 OpenDeck", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 272)
        .onAppear {
            brightness = Double(appModel.config.config.brightness)
        }
    }
}
