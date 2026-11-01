import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 编辑器支撑组件

// 自 EditorView.swift 拆出(2026-11-01 瘦身):取色/应用图标缓存/粘贴板选图/场景联动绑定页。

/// 前台应用自动切换:每页最多绑 3 个应用;可设为默认页
struct SceneAppBindingSheet: View {
    let appModel: AppModel
    let sceneID: UUID

    @Environment(\.dismiss) private var dismiss
    /// 打开面板时扫一次:static 会把「后安装的应用」永久挡在列表外
    @State private var apps: [(bundleID: String, name: String)] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("当 OpenDeck 编辑器窗口关闭且下列应用程序位于前台时,自动切换到本场景。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("绑定的应用程序") {
                    ForEach(0..<3, id: \.self) { slot in
                        LabeledContent("应用程序 \(slot + 1)") {
                            Picker("", selection: binding(for: slot)) {
                                Text("无").tag(String?.none)
                                ForEach(apps, id: \.bundleID) { app in
                                    Text(app.name).tag(String?.some(app.bundleID))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }
                    }
                }
                Section {
                    Toggle("设为默认场景(前台应用无绑定时显示本场景)", isOn: defaultBinding)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(12)
        }
        .frame(width: 480)
        .onAppear { apps = AppModel.installedApps() } // 打开面板时扫描,后装应用也能出现在列表里
    }

    private func binding(for slot: Int) -> Binding<String?> {
        Binding(
            get: { appModel.config.sceneAppBinding(id: sceneID, slot: slot) },
            set: { appModel.config.setSceneAppBinding(id: sceneID, slot: slot, bundleID: $0) }
        )
    }

    private var defaultBinding: Binding<Bool> {
        Binding(
            get: { appModel.config.config.defaultSceneID == sceneID },
            set: { appModel.config.setDefaultScene(id: $0 ? sceneID : nil) }
        )
    }
}

enum FilePicker {
    static func pick(types: [UTType], prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.first?.path
    }
}

/// 键帽配色:hex → SwiftUI Color + 感知亮度(决定文字深浅)。
/// 解析委托 HexCGColor.components(OpenDeck 唯一解析实现,同模块;kit 内的 HexColor
/// 未导出且受 MonitorInputIcon 单文件编译约束不可合并)。这里只负责 SwiftUI 包装
/// 与亮度判断(阈值与 IconRenderer 相同,深浅色文字观感与设备渲染一致)。
struct KeyPalette {
    let color: Color
    let isLight: Bool

    init(hex: String) {
        guard let c = HexCGColor.components(hex) else {
            // 非法输入兜底:暗灰底白字(全库口径:不静默产出错色)
            self.color = Color(white: 0.25)
            self.isLight = false
            return
        }
        self.color = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        self.isLight = (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) > 0.6
    }

    var textColor: Color { isLight ? Color(white: 0.08) : .white }
}

enum AppIconCache {
    static func pngPath(forAppAt appPath: String) -> String? {
        let fileManager = FileManager.default
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenDeck/app-icons", isDirectory: true)
        let key = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
            ?? appPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? "app"
        let fileURL = dir.appendingPathComponent("\(key).png")
        if fileManager.fileExists(atPath: fileURL.path) { return fileURL.path }

        let side: CGFloat = 256
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        icon.size = NSSize(width: side, height: side)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        icon.draw(
            in: NSRect(origin: .zero, size: NSSize(width: side, height: side)),
            from: NSRect(origin: .zero, size: NSSize(width: side, height: side)),
            operation: .sourceOver, fraction: 1.0
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try png.write(to: fileURL) } catch { return nil }
        return fileURL.path
    }
}

