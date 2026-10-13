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
                .frame(minWidth: 640, minHeight: 480)
                .onAppear { appDelegate.appModel = appModel }
        }
        .defaultSize(width: 760, height: 560)

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

/// 菜单栏浮窗:连接状态 + 冲突提示 + 亮度 + 常用操作
private struct MenuBarPanel: View {
    let appModel: AppModel

    @State private var brightness: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appModel.device.state == .running ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(appModel.device.state == .running ? "设备已连接" : "设备未连接")
                    .font(.callout)
                Spacer()
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
            }

            HStack(spacing: 8) {
                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: $brightness, in: 0...100) { editing in
                    if !editing { appModel.commitBrightness() }
                }
                Text("\(Int(brightness))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            .onChange(of: brightness) { _, newValue in
                appModel.setBrightness(Int(newValue))
            }
            .onChange(of: appModel.config.config.brightness) { _, newValue in
                // 与主窗口滑杆互相同步;同值守卫避免回写循环
                if Int(brightness) != newValue {
                    brightness = Double(newValue)
                }
            }

            Divider()

            Button("重新应用到设备") {
                appModel.applyPageToDevice()
            }
            .frame(maxWidth: .infinity)

            Button("退出 OpenDeck") {
                // 经 applicationWillTerminate 触发设备清理,不走直接 exit
                NSApp.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 264)
        .onAppear {
            brightness = Double(appModel.config.config.brightness)
        }
    }
}
