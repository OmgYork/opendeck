import AppKit
import Darwin
import StreamDockKit
import SwiftUI

@main
struct OpenDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    init() {
        // swift run 直跑时 stdout 重定向为块缓冲,日志会憋到退出才出;行缓冲让开发期实时可见
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup("OpenDeck") {
            EditorView(appModel: appModel)
                .onAppear { appDelegate.appModel = appModel }
        }
        .defaultSize(width: 1120, height: 720) // 与 EditorView 的 minWidth 同步(双列 + 矩阵轨放得下)

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

/// 菜单栏浮窗:日常使用的第一界面(编辑器是配置态,面板是驾驶态)。
/// §6.30 前只有亮度/登录项;现补齐「场景/页快速切换 + 熄屏 + 自动熄屏 + 涂黑 + 备份夹」,
/// 与设备键形成互补——手在 Mac 上时不必低头找面板上的翻页键
private struct MenuBarPanel: View {
    let appModel: AppModel

    @State private var brightness: Double = 0

    private var connected: Bool { appModel.device.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            if appModel.officialAppRunning {
                conflictRow
            }

            quickSwitcher

            Divider()

            brightnessRow
            followToggleRow
            optionsRow
            actionRow

            Divider()

            footerRow
        }
        .padding(14)
        .frame(width: 296)
        .onAppear {
            brightness = Double(appModel.config.config.brightness)
        }
    }

    // MARK: 分区

    private var titleRow: some View {
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
    }

    private var conflictRow: some View {
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

    /// 场景/页快速切换:场景每枚一行(当前打勾),当前场景多页时圆点成胶囊行。
    /// 与设备导航键同语义(switchPage/switchScene),编辑器窗口关着时这是唯一的切换出口
    private var quickSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("快速切换")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            let scenes = appModel.config.config.scenes
            ForEach(Array(scenes.enumerated()), id: \.element.id) { offset, scene in
                let isCurrent = scene.id == appModel.config.currentSceneID
                Button {
                    if let id = scene.id, !isCurrent { appModel.switchScene(to: id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isCurrent ? Color.accentColor : .secondary.opacity(0.6))
                            .font(.callout)
                        Text(scene.name.isEmpty ? "场景 \(offset + 1)" : scene.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text("\(scene.pages.count) 页")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            // 当前场景多页:圆点行(主页=第 1 页,其余圆点)
            if scenes.indices.contains(appModel.config.config.currentSceneIndex) {
                let pages = scenes[appModel.config.config.currentSceneIndex].pages
                if pages.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { pageIndex in
                            let isCurrentPage = pageIndex == appModel.config.config.currentPageIndex
                            Button {
                                appModel.config.currentPageIndex = pageIndex
                                appModel.applyPageToDevice()
                            } label: {
                                Text(pageIndex == 0 ? "主" : "\(pageIndex + 1)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 26, height: 20)
                                    .background(
                                        (isCurrentPage ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(isCurrentPage ? .primary : .secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var brightnessRow: some View {
        HStack(spacing: 8) {
            Image(systemName: appModel.followSystemBrightness ? "sun.max.fill" : (brightness < 15 ? "sun.min" : "sun.max.fill"))
                .foregroundStyle(.yellow)
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            Slider(value: Binding(
                get: { brightness },
                set: { newValue in
                    brightness = newValue
                    appModel.setBrightness(Int(newValue))
                }
            ), in: 0...100) { editing in
                if !editing { appModel.commitBrightness() }
            }
            Text("\(Int(brightness))%")
                .font(.callout.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
        .onChange(of: appModel.config.brightness) { _, newValue in
            // 与主窗口滑杆互相同步;同值守卫避免回写循环
            if Int(brightness) != newValue {
                brightness = Double(newValue)
            }
        }
    }

    private var followToggleRow: some View {
        Toggle("亮度跟随 MacBook", isOn: Binding(
            get: { appModel.followSystemBrightness },
            set: { appModel.setFollowSystemBrightness($0) }
        ))
    }

    /// 滑杆 0% 涂黑与自动熄屏此前只在编辑器 ⋯ 菜单:都是日常开关,补到面板
    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("滑杆 0% 时键面涂黑", isOn: Binding(
                get: { appModel.config.sliderZeroBlacksKeys },
                set: { appModel.setSliderZeroBlacksKeys($0) }
            ))
            HStack {
                Text("自动熄屏")
                Spacer()
                Picker("", selection: Binding(
                    get: { appModel.config.autoScreenOffMinutes },
                    set: { appModel.setAutoScreenOffMinutes($0) }
                )) {
                    Text("关").tag(0)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30)
                    Text("60 分钟").tag(60)
                }
                .labelsHidden()
                .frame(width: 96)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                appModel.device.screenOff()
            } label: {
                Label("熄屏", systemImage: "moon.zzz.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button {
                appModel.applyPageToDevice()
            } label: {
                Label("重新应用", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                NSWorkspace.shared.open(AppModel.autoBackupRoot)
            } label: {
                Label("自动备份文件夹", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            Button {
                // 经 applicationWillTerminate 触发设备清理,不走直接 exit
                NSApp.terminate(nil)
            } label: {
                Label("退出 OpenDeck", systemImage: "power")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("登录时启动", isOn: Binding(
                get: { appModel.isLaunchAtLoginEnabled },
                set: { appModel.setLaunchAtLogin($0) }
            ))
        }
    }
}
