import AppKit
import StreamDockKit
import SwiftUI

// MARK: - 模板配置 Sheet(自 EditorView.swift 拆出,§6.30 文件卫生)

// MARK: - 键位编辑 Sheet



/// 点击调色盘里的模板磁贴弹出:配参数 → 保存为就绪态(持久化在 config.templateDrafts)
/// → 拖拽磁贴到键位即完整键;**一次性**——落键即消费草稿,磁贴复原;再点磁贴 = 改配置。
/// 只收 6 种带参模板;复用 KeyEditView 同款捕获组件(HotkeyCaptureField/FilePicker),
/// 参数口径与 KeyEditView.assembledAction 一致(空参不成动作,含空脚本)。
struct TemplateConfigSheet: View {
    let kind: KeyTemplate
    /// 已有就绪态(再点磁贴 = 改配置)
    let initial: KeyConfig?
    var onSave: (KeyConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var appPath: String
    @State private var urlString: String
    @State private var shortcutName: String
    @State private var scriptText: String
    @State private var hotkeyKeyCode: Int?
    @State private var hotkeyModifiers: [String]
    /// 打开应用的键面底图(应用真实图标,AppIconCache 落盘缓存)
    @State private var iconPath: String?

    private var defaultTitle: String {
        FunctionPaletteCatalog.item(forPayload: "template:\(kind.rawValue)")?.title ?? "未命名"
    }

    init(kind: KeyTemplate, initial: KeyConfig?, onSave: @escaping (KeyConfig) -> Void) {
        self.kind = kind
        self.initial = initial
        self.onSave = onSave
        var appPath = ""
        var urlString = ""
        var shortcutName = ""
        var scriptText = ""
        var keyCode: Int?
        var modifiers: [String] = []
        switch initial?.action {
        case .openApp(let path): appPath = path
        case .openURL(let url): urlString = url
        case .runShortcut(let name): shortcutName = name
        case .shellScript(let script): scriptText = script
        case .appleScript(let script): scriptText = script
        case .hotkey(let code, let mods): keyCode = code; modifiers = mods
        default: break
        }
        _title = State(initialValue: initial?.title ?? "")
        _appPath = State(initialValue: appPath)
        _urlString = State(initialValue: urlString)
        _shortcutName = State(initialValue: shortcutName)
        _scriptText = State(initialValue: scriptText)
        _hotkeyKeyCode = State(initialValue: keyCode)
        _hotkeyModifiers = State(initialValue: modifiers)
        _iconPath = State(initialValue: initial?.iconPath)
    }

    /// 参数口径与 KeyEditView 同源:组装走 KeyTemplate.assemble 单函数(空参不成动作,含空脚本)
    private var assembledAction: KeyAction? {
        KeyTemplate.assemble(kind, appPath: appPath, urlString: urlString,
                             shortcutName: shortcutName, scriptText: scriptText,
                             hotkeyKeyCode: hotkeyKeyCode, hotkeyModifiers: hotkeyModifiers)
    }

    private var draftConfig: KeyConfig {
        KeyConfig(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? defaultTitle : title,
            backgroundColorHex: "#3B4252",
            iconPath: iconPath,
            action: assembledAction,
            animation: nil,
            template: nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        KeycapView(config: draftConfig, interactive: false)
                            .frame(width: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("就绪磁贴预览")
                                .font(.subheadline.weight(.semibold))
                            Text("保存后拖拽此磁贴到键位即完成绑定")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("外观") {
                    LabeledContent("标题") {
                        TextField(defaultTitle, text: $title)
                    }
                }
                Section("参数") {
                    parameterForm
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard assembledAction != nil else { return }
                    onSave(draftConfig)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(assembledAction == nil)
            }
            .padding(12)
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private var parameterForm: some View {
        switch kind {
        case .openApp:
            LabeledContent("应用") {
                HStack {
                    Text(appPath.isEmpty ? "未选择" : (appPath as NSString).lastPathComponent)
                        .foregroundStyle(appPath.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Button("选择应用…") {
                        if let path = FilePicker.pick(types: [.application], prompt: "选择要打开的应用") {
                            appPath = path
                            // 自动带出应用显示名与真实图标(标题仍可手改,重选应用即覆盖)
                            title = FileManager.default.displayName(atPath: path)
                            iconPath = AppIconCache.pngPath(forAppAt: path)
                        }
                    }
                }
            }
        case .openURL:
            LabeledContent("网址") {
                TextField("https://example.com", text: $urlString)
            }
        case .runShortcut:
            LabeledContent("快捷指令名称") {
                TextField("Shortcuts 应用里的名称", text: $shortcutName)
            }
        case .shellScript:
            scriptEditor("以 zsh -c 执行")
        case .appleScript:
            scriptEditor("以 osascript 执行")
        case .hotkey:
            LabeledContent("组合键") {
                HotkeyCaptureField(keyCode: $hotkeyKeyCode, modifiers: $hotkeyModifiers)
            }
        }
    }

    private func scriptEditor(_ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $scriptText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 待配置模板 → 编辑器预选类型:调色盘模板磁贴落下后(action = nil)首次点开,
/// 直接落到对应表单,不必在下拉菜单里重选一遍
extension KeyTemplate {
    var actionKind: ActionKind {
        switch self {
        case .openApp: .openApp
        case .openURL: .openURL
        case .runShortcut: .runShortcut
        case .shellScript: .shellScript
        case .appleScript: .appleScript
        case .hotkey: .hotkey
        }
    }
}

/// ActionKind ↔ KeyTemplate 桥接:带参模板的组装与预选共用(单源在 KeyTemplate.assemble)
extension ActionKind {
    /// 该类型若属六种带参模板,给出对应 KeyTemplate
    var templateKind: KeyTemplate? {
        switch self {
        case .openApp: .openApp
        case .openURL: .openURL
        case .runShortcut: .runShortcut
        case .shellScript: .shellScript
        case .appleScript: .appleScript
        case .hotkey: .hotkey
        default: nil
        }
    }
}

/// 编辑器里的动作类型选择;与 KeyAction 一一对应,外加"无动作"
enum ActionKind: Hashable, CaseIterable {
    case none
    case openApp
    case openURL
    case runShortcut
    case shellScript
    case appleScript
    case hotkey
    case mediaKey
    case previousPage
    case nextPage
    case previousScene
    case nextScene
    case pageIndicator
    case screenOff
    case sleepGuard
    case plugin
    case monitor
    case stat
    case heatmap
    /// 旧版「前往指定页」:只读展示(选择器已移除),保存即清除——替代原「静默显示为无动作」
    case gotoPageLegacy

    var label: String {
        switch self {
        case .none: "无动作"
        case .openApp: "打开应用"
        case .openURL: "打开网址"
        case .runShortcut: "运行快捷指令"
        case .shellScript: "Shell 脚本"
        case .appleScript: "AppleScript"
        case .hotkey: "键盘按键（热键）"
        case .mediaKey: "媒体控制"
        case .previousPage: "上一页"
        case .nextPage: "下一页"
        case .previousScene: "上一场景"
        case .nextScene: "下一场景"
        case .pageIndicator: "页面指示"
        case .screenOff: "熄屏"
        case .sleepGuard: "合盖休眠锁"
        case .plugin: "插件动作"
        case .monitor: "显示器（DDC）"
        case .stat: "系统状态（GPU/CPU/温度）"
        case .heatmap: "键盘热力图（读取 KeyAnalyze）"
        case .gotoPageLegacy: "前往指定页（旧版）"
        }
    }
}

