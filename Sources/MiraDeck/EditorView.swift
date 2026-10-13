import AppKit
import StreamDockKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 主编辑器

/// 18 键网格编辑器:顶部状态区(连接状态/冲突警示/亮度)+ 键位网格 + 编辑 Sheet
struct EditorView: View {
    let appModel: AppModel

    @State private var editingTarget: EditTarget?
    @State private var brightness: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                keyGrid
                    .padding(16)
            }
        }
        .task { appModel.start() }
        .onAppear {
            brightness = Double(appModel.config.config.brightness)
            // 设备未连接时 drawKey 只入缓存,连接校准时控制器会自动全量重画
            appModel.applyPageToDevice()
        }
        .onChange(of: appModel.device.state) { _, state in
            if state == .running { appModel.applyPageToDevice() }
        }
        .onChange(of: appModel.config.currentPageIndex) { _, _ in
            appModel.applyPageToDevice()
        }
        .sheet(item: $editingTarget) { target in
            KeyEditView(index: target.index, appModel: appModel)
        }
    }

    // MARK: 顶部状态区

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appModel.device.state == .running ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(appModel.device.state == .running ? "Stream Dock 已连接" : "未连接设备")
                    .font(.callout.weight(.medium))
                Text(appModel.config.currentPage.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let log = appModel.latestLog {
                    Text(log)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 320)
                        .help(appModel.recentLogs.joined(separator: "\n"))
                }
            }

            if appModel.officialAppRunning {
                conflictBanner
            }

            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: $brightness, in: 0...100) { editing in
                    if !editing { appModel.commitBrightness() }
                }
                Text("\(Int(brightness))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            .onChange(of: brightness) { _, newValue in
                appModel.setBrightness(Int(newValue))
            }
            .onChange(of: appModel.config.config.brightness) { _, newValue in
                // 与菜单栏浮窗互相同步;同值守卫避免回写循环
                if Int(brightness) != newValue {
                    brightness = Double(newValue)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("官方 StreamDock 正在运行,两者会互相干扰")
                .font(.callout)
            Spacer()
            Button("帮我退出它") {
                appModel.quitOfficialApp()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 键位网格

    private var keyGrid: some View {
        LazyVGrid(columns: Self.gridColumns, spacing: 8) {
            ForEach(0..<(StreamDock293S.rows * StreamDock293S.columns), id: \.self) { index in
                KeyGridCell(key: appModel.config.keyConfig(at: index)) {
                    editingTarget = EditTarget(index: index)
                }
            }
        }
    }

    // 第 6 列是设备软键(80×80,主键 100×100),收窄以贴近真实键面比例
    private static let gridColumns: [GridItem] =
        Array(repeating: GridItem(.flexible(), spacing: 8), count: StreamDock293S.columns - 1)
        + [GridItem(.fixed(76), spacing: 8)]
}

/// Sheet 的 item 包装(Int 本身不携带语义,包一层可读性更好)
private struct EditTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - 键位网格单元

private struct KeyGridCell: View {
    let key: KeyConfig
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            preview
        }
        .buttonStyle(.plain)
    }

    private var preview: some View {
        let palette = KeyPalette(hex: key.backgroundColorHex)
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(palette.color)
            if let path = key.iconPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if let action = key.action {
                Image(systemName: ActionStyle.symbol(for: action))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.textColor.opacity(0.9))
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if !key.title.isEmpty {
                Text(key.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textColor)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(palette.isLight ? 0 : 0.6), radius: 2, y: 1)
                    .padding(6)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

// MARK: - 键位编辑 Sheet

private struct KeyEditView: View {
    private static let presetColors = [
        "#1E88E5", "#E53935", "#43A047", "#FB8C00",
        "#8E24AA", "#00ACC1", "#FDD835", "#455A64",
    ]

    /// 独立小类型而非元组:key path(ForEach id)无法引用元组元素
    private struct MediaKeyOption: Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }

    private static let mediaKeys: [MediaKeyOption] = [
        .init(value: "playPause", label: "播放 / 暂停"),
        .init(value: "next", label: "下一曲"),
        .init(value: "previous", label: "上一曲"),
        .init(value: "volumeUp", label: "增大音量"),
        .init(value: "volumeDown", label: "减小音量"),
        .init(value: "mute", label: "静音"),
    ]

    let index: Int
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss

    // 编辑期间使用草稿字段,保存时才写回配置,取消即丢弃
    @State private var title: String
    @State private var colorHex: String
    @State private var iconPath: String?
    @State private var kind: ActionKind
    @State private var appPath: String
    @State private var urlString: String
    @State private var shortcutName: String
    @State private var scriptText: String
    @State private var hotkeyKeyCode: Int?
    @State private var hotkeyModifiers: [String]
    @State private var mediaKeyValue: String

    init(index: Int, appModel: AppModel) {
        self.index = index
        self.appModel = appModel
        let key = appModel.config.keyConfig(at: index)
        _title = State(initialValue: key.title)
        _colorHex = State(initialValue: key.backgroundColorHex)
        _iconPath = State(initialValue: key.iconPath)

        var kind = ActionKind.none
        var appPath = ""
        var urlString = ""
        var shortcutName = ""
        var scriptText = ""
        var keyCode: Int?
        var modifiers: [String] = []
        var mediaKey = "playPause"
        switch key.action {
        case .openApp(let path): kind = .openApp; appPath = path
        case .openURL(let url): kind = .openURL; urlString = url
        case .runShortcut(let name): kind = .runShortcut; shortcutName = name
        case .shellScript(let script): kind = .shellScript; scriptText = script
        case .appleScript(let script): kind = .appleScript; scriptText = script
        case .hotkey(let code, let mods): kind = .hotkey; keyCode = code; modifiers = mods
        case .mediaKey(let name): kind = .mediaKey; mediaKey = name
        case nil: break
        }
        _kind = State(initialValue: kind)
        _appPath = State(initialValue: appPath)
        _urlString = State(initialValue: urlString)
        _shortcutName = State(initialValue: shortcutName)
        _scriptText = State(initialValue: scriptText)
        _hotkeyKeyCode = State(initialValue: keyCode)
        _hotkeyModifiers = State(initialValue: modifiers)
        _mediaKeyValue = State(initialValue: mediaKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("外观") {
                    LabeledContent("标题") {
                        TextField("按键标题(留空则只显示图标)", text: $title)
                    }
                    LabeledContent("颜色") { colorPicker }
                    LabeledContent("图标") { iconRow }
                }
                Section("动作") {
                    Picker("类型", selection: $kind) {
                        ForEach(ActionKind.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    actionForm
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500)
    }

    // MARK: 外观控件

    private var colorPicker: some View {
        HStack(spacing: 8) {
            ForEach(Self.presetColors, id: \.self) { hex in
                Button {
                    colorHex = hex
                } label: {
                    Circle()
                        .fill(KeyPalette(hex: hex).color)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if colorHex == hex {
                                Circle().strokeBorder(Color.primary, lineWidth: 2)
                                    .padding(-3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(hex)
            }
            Spacer()
            TextField("#RRGGBB", text: $colorHex)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
        }
    }

    private var iconRow: some View {
        HStack(spacing: 8) {
            if let iconPath {
                Text((iconPath as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(iconPath)
            } else {
                Text("未设置,仅使用背景色")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if iconPath != nil {
                Button("清除") { iconPath = nil }
            }
            Button("选择图片…") {
                if let path = FilePicker.pick(types: [.image], prompt: "选择键面图标") {
                    iconPath = path
                }
            }
        }
    }

    // MARK: 动作控件(按类型切换动态表单)

    @ViewBuilder
    private var actionForm: some View {
        switch kind {
        case .none:
            LabeledContent("说明") {
                Text("按下该键不执行任何操作")
                    .foregroundStyle(.secondary)
            }
        case .openApp:
            LabeledContent("应用") {
                HStack {
                    if appPath.isEmpty {
                        Text("未选择").foregroundStyle(.secondary)
                    } else {
                        Text(appPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(appPath)
                    }
                    Spacer()
                    Button("选择应用…") {
                        if let path = FilePicker.pick(types: [.application], prompt: "选择要打开的应用") {
                            appPath = path
                        }
                    }
                }
            }
        case .openURL:
            LabeledContent("网址") {
                TextField("https://example.com", text: $urlString)
            }
        case .runShortcut:
            LabeledContent("快捷指令") {
                TextField("在「快捷指令」app 中的名称", text: $shortcutName)
            }
        case .shellScript:
            scriptEditor
        case .appleScript:
            scriptEditor
        case .hotkey:
            LabeledContent("组合键") {
                HotkeyCaptureField(keyCode: $hotkeyKeyCode, modifiers: $hotkeyModifiers)
            }
        case .mediaKey:
            LabeledContent("操作") {
                Picker("", selection: $mediaKeyValue) {
                    ForEach(Self.mediaKeys, id: \.value) { item in
                        Text(item.label).tag(item.value)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        }
    }

    private var scriptEditor: some View {
        TextEditor(text: $scriptText)
            .font(.system(.body, design: .monospaced))
            .frame(height: 110)
            .scrollContentBackground(.hidden)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 保存

    private var normalizedColorHex: String {
        var value = colorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.hasPrefix("#") { value = "#" + value }
        return value
    }

    private var assembledAction: KeyAction? {
        switch kind {
        case .none:
            nil
        case .openApp:
            appPath.isEmpty ? nil : .openApp(path: appPath)
        case .openURL:
            urlString.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .openURL(urlString)
        case .runShortcut:
            shortcutName.isEmpty ? nil : .runShortcut(name: shortcutName)
        case .shellScript:
            .shellScript(scriptText)
        case .appleScript:
            .appleScript(scriptText)
        case .hotkey:
            if let code = hotkeyKeyCode {
                .hotkey(keyCode: code, modifiers: hotkeyModifiers)
            } else {
                nil
            }
        case .mediaKey:
            .mediaKey(mediaKeyValue)
        }
    }

    private func save() {
        let key = KeyConfig(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            backgroundColorHex: normalizedColorHex,
            iconPath: iconPath,
            action: assembledAction
        )
        appModel.config.updateKey(key, at: index)
        appModel.applyKey(at: index)
        dismiss()
    }
}

/// 编辑器里的动作类型选择;与 KeyAction 一一对应,外加"无动作"
private enum ActionKind: Hashable, CaseIterable {
    case none
    case openApp
    case openURL
    case runShortcut
    case shellScript
    case appleScript
    case hotkey
    case mediaKey

    var label: String {
        switch self {
        case .none: "无动作"
        case .openApp: "打开应用"
        case .openURL: "打开网址"
        case .runShortcut: "运行快捷指令"
        case .shellScript: "Shell 脚本"
        case .appleScript: "AppleScript"
        case .hotkey: "全局热键"
        case .mediaKey: "媒体控制"
        }
    }
}

// MARK: - 全局热键捕获

/// 录制期间用 NSEvent local monitor 截获本应用全部按键事件:
/// 比 NSView keyDown 可靠(不受焦点状态与菜单键等价拦截影响),且无需辅助功能权限。
/// 生命周期纪律:start 前必 end;捕获到组合键或 ⎋ 后立即 end;视图消失兜底 end,
/// 确保 monitor 绝不会在录制之外吞键。
@MainActor
private final class HotkeyCaptureMonitor {
    private var token: Any?

    var onCapture: ((Int, [String]) -> Void)?
    var onCancel: (() -> Void)?
    var onModifiersChanged: ((String) -> Void)?

    func start() {
        end()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func end() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
    }

    /// 返回 nil 表示吞掉该事件(录制期间按键不应再触发输入框/快捷键)
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            onModifiersChanged?(HotkeySymbols.modifierPreview(for: event.modifierFlags))
            return nil
        case .keyDown:
            // ⎋ 语义 = 取消录制:⎋ 本身几乎不会被设为热键,还能避免顺带关闭 Sheet
            if event.keyCode == 53 {
                end()
                onCancel?()
                return nil
            }
            let modifiers = HotkeySymbols.configModifiers(for: event.modifierFlags)
            end()
            onCapture?(Int(event.keyCode), modifiers)
            return nil
        default:
            return event
        }
    }
}

private struct HotkeyCaptureField: View {
    @Binding var keyCode: Int?
    @Binding var modifiers: [String]

    @State private var monitor = HotkeyCaptureMonitor()
    @State private var recording = false
    @State private var livePreview = ""

    var body: some View {
        HStack(spacing: 8) {
            display
            Spacer()
            if recording {
                Button("取消") { stopRecording() }
            } else {
                Button(keyCode == nil ? "录制" : "重新录制") { startRecording() }
            }
            if keyCode != nil, !recording {
                Button {
                    keyCode = nil
                    modifiers = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除组合键")
            }
        }
        .onDisappear {
            monitor.end()
            recording = false
        }
    }

    @ViewBuilder
    private var display: some View {
        if recording {
            Label(
                livePreview.isEmpty ? "请按下组合键,⎋ 取消" : "\(livePreview) …",
                systemImage: "record.circle"
            )
            .foregroundStyle(.orange)
        } else if let code = keyCode {
            Text(HotkeySymbols.displayString(keyCode: code, modifiers: modifiers))
                .font(.system(.body, design: .monospaced).weight(.medium))
        } else {
            Text("未设置").foregroundStyle(.secondary)
        }
    }

    private func startRecording() {
        livePreview = ""
        recording = true
        monitor.onCapture = { code, mods in
            keyCode = code
            modifiers = mods
            recording = false
        }
        monitor.onCancel = { recording = false }
        monitor.onModifiersChanged = { preview in
            livePreview = preview
        }
        monitor.start()
    }

    private func stopRecording() {
        monitor.end()
        recording = false
        livePreview = ""
    }
}

/// keyCode/修饰键 ↔ 显示符号、配置字符串的转换(按美式 ANSI 布局)
private enum HotkeySymbols {
    private static let keyNames: [Int: String] = [
        // 字母区(kVK_ANSI_A…Z 扫描码不连续)
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        // 数字行与符号
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".",
        // 常用功能键
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 117: "⌦",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        118: "F4", 119: "End", 120: "F2", 122: "F1",
        115: "Home", 116: "PageUp", 121: "PageDown",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func displayString(keyCode: Int, modifiers: [String]) -> String {
        modifierSymbols(modifiers) + (keyNames[keyCode] ?? "Key(\(keyCode))")
    }

    /// 已存配置的修饰键 → 展示符号,顺序遵循 macOS 惯例 ⌃⌥⇧⌘
    static func modifierSymbols(_ modifiers: [String]) -> String {
        var out = ""
        if modifiers.contains("control") { out += "⌃" }
        if modifiers.contains("option") { out += "⌥" }
        if modifiers.contains("shift") { out += "⇧" }
        if modifiers.contains("command") { out += "⌘" }
        return out
    }

    /// 录制中按住修饰键时的实时预览
    static func modifierPreview(for flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    /// NSEvent 修饰键 → 配置层字符串(契约取值:command/option/control/shift)
    static func configModifiers(for flags: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if flags.contains(.command) { out.append("command") }
        if flags.contains(.option) { out.append("option") }
        if flags.contains(.control) { out.append("control") }
        if flags.contains(.shift) { out.append("shift") }
        return out
    }
}

// MARK: - 动作角标

/// 动作 → 网格单元格右上角的 SF Symbol 角标
private enum ActionStyle {
    static func symbol(for action: KeyAction) -> String {
        switch action {
        case .openApp: "app"
        case .openURL: "link"
        case .runShortcut: "wand.and.stars"
        case .shellScript: "terminal"
        case .appleScript: "chevron.left.forwardslash.chevron.right"
        case .hotkey: "keyboard"
        case .mediaKey: "play.circle"
        }
    }
}

// MARK: - 小工具

/// 键面 hex 颜色的 UI 侧解析。
/// StreamDockKit 内部的 HexColor 未导出,且 UI 预览(Color)与设备渲染(CGImage)
/// 所需的类型不同,这里独立实现并用与 IconRenderer 相同的亮度阈值保证观感一致。
private struct KeyPalette {
    let color: Color
    let isLight: Bool

    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard (6...8).contains(value.count), let raw = UInt64(value, radix: 16) else {
            self.color = Color(white: 0.25)
            self.isLight = false
            return
        }
        let r: Double
        let g: Double
        let b: Double
        let alpha: Double
        if value.count == 8 {
            r = Double((raw >> 24) & 0xff) / 255
            g = Double((raw >> 16) & 0xff) / 255
            b = Double((raw >> 8) & 0xff) / 255
            alpha = Double(raw & 0xff) / 255
        } else {
            r = Double((raw >> 16) & 0xff) / 255
            g = Double((raw >> 8) & 0xff) / 255
            b = Double(raw & 0xff) / 255
            alpha = 1
        }
        self.color = Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
        // 与 IconRenderer 相同的感知亮度阈值,深浅色文字判断与设备渲染一致
        self.isLight = (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.6
    }

    var textColor: Color { isLight ? Color(white: 0.08) : .white }
}

/// NSOpenPanel 的最小封装;runModal 在主线程阻塞是 AppKit 模态的标准用法
@MainActor
private enum FilePicker {
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
