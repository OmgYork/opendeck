import AppKit
import SwiftUI

// MARK: - 键位编辑 Sheet

// 自 EditorView.swift 拆出(2026-11-01 瘦身):每个动作类型的表单/组装/保存,
// 是编辑器里最大的一块独立 UI(草稿模式范本,见 docs/subsystem-integration.md §5)。

struct KeyEditView: View {
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
    /// 原动作:同键保存同插件动作时复用 contextID(实例身份跨保存稳定)
    private let originalAction: KeyAction?

    @Environment(\.dismiss) private var dismiss

    // 编辑期间使用草稿字段,保存时才写回配置,取消即丢弃
    @State private var title: String
    @State private var colorHex: String
    @State private var iconPath: String?
    @State private var animation: KeyAnimation?
    @State private var kind: ActionKind
    @State private var appPath: String
    @State private var urlString: String
    @State private var shortcutName: String
    @State private var scriptText: String
    @State private var hotkeyKeyCode: Int?
    @State private var hotkeyModifiers: [String]
    @State private var mediaKeyValue: String
    @State private var pluginID: String
    @State private var pluginActionUUID: String
    /// 显示器动作草稿:托盘拖到键位后,点开该键编辑时也落到这里
    @State private var monitorCommand: MonitorCommand
    /// 系统状态草稿:GPU/CPU/温度
    @State private var statKind: StatKind
    /// 草稿实例身份:PI(webview 生命周期)与保存组装共用,必须跨渲染稳定。
    /// 原动作未变 = 复用持久化 contextID;换了动作 = onChange 时一次性生成新 UUID。
    @State private var draftContextID: String
    /// 多状态动作手动轮换的本地重渲信号(见 pluginActionForm 内注释)
    @State private var stateCycleCount = 0

    init(index: Int, appModel: AppModel) {
        self.index = index
        self.appModel = appModel
        let key = appModel.config.keyConfig(at: index)
        originalAction = key.action
        _title = State(initialValue: key.title)
        _colorHex = State(initialValue: key.backgroundColorHex)
        _iconPath = State(initialValue: key.iconPath)
        _animation = State(initialValue: key.animation)

        var kind = ActionKind.none
        var appPath = ""
        var urlString = ""
        var shortcutName = ""
        var scriptText = ""
        var keyCode: Int?
        var modifiers: [String] = []
        var mediaKey = "playPause"
        var pluginID = ""
        var pluginActionUUID = ""
        var draftContextID = ""
        var monitorCommand = MonitorCommand.brightnessUp
        var statKind = StatKind.gpu
        switch key.action {
        case .openApp(let path): kind = .openApp; appPath = path
        case .openURL(let url): kind = .openURL; urlString = url
        case .runShortcut(let name): kind = .runShortcut; shortcutName = name
        case .shellScript(let script): kind = .shellScript; scriptText = script
        case .appleScript(let script): kind = .appleScript; scriptText = script
        case .hotkey(let code, let mods): kind = .hotkey; keyCode = code; modifiers = mods
        case .mediaKey(let name): kind = .mediaKey; mediaKey = name
        case .plugin(let id, let actionUUID, let contextID):
            kind = .plugin
            pluginID = id
            pluginActionUUID = actionUUID
            draftContextID = contextID
        case .previousPage: kind = .previousPage
        case .nextPage: kind = .nextPage
        case .previousScene: kind = .previousScene
        case .nextScene: kind = .nextScene
        case .gotoPage: kind = .gotoPageLegacy // 旧动作:只读可见,保存即清除(不再静默伪装成「无动作」)
        case .pageIndicator: kind = .pageIndicator
        case .screenOff: kind = .screenOff
        case .sleepGuard: kind = .sleepGuard
        case .monitor(let command): kind = .monitor; monitorCommand = command
        case .stat(let statKind): kind = .stat; self.statKind = statKind
        case .keyboardHeatmap: kind = .heatmap
        case nil:
            // 待配置模板占位(调色盘模板磁贴落下):预选类型、参数留空,补齐后保存即落定
            if let template = key.template { kind = template.actionKind }
        }
        _kind = State(initialValue: kind)
        _appPath = State(initialValue: appPath)
        _urlString = State(initialValue: urlString)
        _shortcutName = State(initialValue: shortcutName)
        _scriptText = State(initialValue: scriptText)
        _hotkeyKeyCode = State(initialValue: keyCode)
        _hotkeyModifiers = State(initialValue: modifiers)
        _mediaKeyValue = State(initialValue: mediaKey)
        _pluginID = State(initialValue: pluginID)
        _pluginActionUUID = State(initialValue: pluginActionUUID)
        _draftContextID = State(initialValue: draftContextID)
        _monitorCommand = State(initialValue: monitorCommand)
        _statKind = State(initialValue: statKind)
    }

    /// 草稿状态组装出的键配置——live 预览与保存共用,保证「所见即所得」
    private var draftConfig: KeyConfig {
        KeyConfig(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            backgroundColorHex: normalizedColorHex,
            iconPath: iconPath,
            action: assembledAction,
            animation: animation,
            template: nil  // 保存即落定:清除模板占位(取消编辑则保留占位)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        KeycapView(config: draftConfig, interactive: false,
                                   staticFrame: appModel.animationPreviewFrame(for: draftConfig))
                            .frame(width: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("实时预览")
                                .font(.subheadline.weight(.semibold))
                            Text("与设备键面 1:1 渲染")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("外观") {
                    LabeledContent("标题") {
                        TextField("按键标题(留空则只显示图标)", text: $title)
                    }
                    LabeledContent("颜色") { colorPicker }
                    LabeledContent("图标") { iconRow }
                    LabeledContent("动效") {
                        Toggle("显示器输入切换", isOn: Binding(
                            get: { animation == .monitorInput },
                            set: { animation = $0 ? .monitorInput : nil }
                        ))
                    }
                    if animation == .monitorInput {
                        Text("键面实时显示当前输入源(Mac / PC),按压时播放信号迁移动效。开启后标题与图标不再叠加。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("动作") {
                    Picker("类型", selection: $kind) {
                        ForEach(ActionKind.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    actionForm
                }
                if kind == .plugin {
                    piSection
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("清除此键", role: .destructive) { clearKey() }
                    .help("动作 / 动效 / 标题 / 图标全部清空，立即保存上屏")
                Spacer()
                Button("取消") { cancelEdit() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                // 防「看起来配好了的死键」:选了动作类型但参数没填全时禁用保存
                // (「无动作」是显式清空、旧版 gotoPage 是文档化的清除路径,两者均可保存)
                .disabled(kind != .none && kind != .gotoPageLegacy && assembledAction == nil)
                .help(kind != .none && kind != .gotoPageLegacy && assembledAction == nil ? "参数未填全,该键将不会执行任何动作" : "")
            }
            .padding(12)
        }
        .frame(width: 520)
    }

    /// 动作参数(Property Inspector):插件动作带 PI 页时内嵌 webview,即改即存
    @ViewBuilder
    private var piSection: some View {
        if case .plugin(let pluginID, let actionUUID, let contextID) = assembledPluginAction {
            if appModel.pluginHost.port != 0,
               let piURL = appModel.pluginHost.piPageURL(pluginID: pluginID, actionUUID: actionUUID),
               let pluginRoot = appModel.pluginHost.pluginRootURL(pluginID: pluginID),
               let appJSON = appModel.pluginHost.piRegistrationInfoJSON(pluginID: pluginID) {
                Section("动作参数(Property Inspector)") {
                    PropertyInspectorView(
                        pageURL: piURL,
                        readAccessRoot: pluginRoot,
                        port: appModel.pluginHost.port,
                        contextID: contextID,
                        appJSON: appJSON,
                        actionInfoJSON: appModel.pluginHost.piActionInfoJSON(
                            pluginID: pluginID, actionUUID: actionUUID, contextID: contextID
                        )
                    )
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id("\(pluginID)/\(actionUUID)/\(contextID)") // 换动作/换实例即重建 webview
                    .onAppear {
                        appModel.pluginHost.prepareForPI(pluginUUID: pluginID)
                        appModel.pluginHost.registerPendingPI(
                            pluginUUID: pluginID, actionUUID: actionUUID, contextID: contextID
                        )
                    }
                    .onDisappear {
                        appModel.pluginHost.clearPendingPI(contextID: contextID)
                    }
                }
            } else {
                Section {
                    LabeledContent("参数") {
                        Text(appModel.pluginHost.port != 0
                            ? "该动作无可配置参数"
                            : "插件宿主未就绪,重开编辑器即可加载参数面板")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
        case .plugin:
            pluginActionForm
        case .heatmap:
            LabeledContent("说明") {
                Text("键面显示 KeyAnalyze 的今日按键数：常态按下打开 dashboard，中断态按下触发它的「重试统计」。数据与状态都取自该应用自身，不自建统计。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .gotoPageLegacy:
            LabeledContent("说明") {
                Text("旧版「前往指定页」动作（选择器已移除），此键目前仍可正常使用；一旦保存，该动作即被清除。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .monitor:
            LabeledContent("功能") {
                Picker("", selection: $monitorCommand) {
                    ForEach(MonitorGroup.allCases.filter { group in
                        MonitorCommand.allCases.contains { $0.group == group }
                    }) { group in
                        Section(group.title) {
                            ForEach(MonitorCommand.allCases.filter { $0.group == group }) { command in
                                Text(command.title).tag(command)
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            if let note = monitorCommand.spec.note {
                Text("VCP 0x\(String(monitorCommand.spec.code, radix: 16))　\(note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .stat:
            LabeledContent("监视项") {
                Picker("", selection: $statKind) {
                    ForEach(StatKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            LabeledContent("说明") {
                Text("键面整帧实时刷新(2s 采样);放哪哪显示,清除即消失")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .previousPage:
            LabeledContent("说明") { Text("在当前场景内循环切到上一页").foregroundStyle(.secondary) }
        case .nextPage:
            LabeledContent("说明") { Text("在当前场景内循环切到下一页").foregroundStyle(.secondary) }
        case .previousScene:
            LabeledContent("说明") { Text("循环切到上一场景(落到其第一页)").foregroundStyle(.secondary) }
        case .nextScene:
            LabeledContent("说明") { Text("循环切到下一场景(落到其第一页)").foregroundStyle(.secondary) }
        case .pageIndicator:
            LabeledContent("说明") { Text("键面实时显示当前页码(N/M),随页面切换自动刷新").foregroundStyle(.secondary) }
        case .screenOff:
            LabeledContent("说明") { Text("面板黑屏待机,按任意键唤醒(该次按压不触发动作)").foregroundStyle(.secondary) }
        case .sleepGuard:
            LabeledContent("说明") {
                Text("切换合盖是否休眠(pmset disablesleep)。键面实时回显:绿=合盖不睡,灰=正常休眠。需要 sudoers 免密规则;缺授权时按键会弹一次提示。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 插件动作:已装 Node 插件 → 其 Keypad 型动作 两级选择
    private var pluginActionForm: some View {
        let hostablePlugins = appModel.pluginHost.installedPlugins.filter { $0.manifest.family.isHostable }
        let selected = hostablePlugins.first { $0.manifest.pluginUUID == pluginID }
        return Group {
            if hostablePlugins.isEmpty {
                LabeledContent("说明") {
                    Text("尚未安装插件。请从菜单栏「⋯ → 插件管理…」安装 .sdPlugin 或导入官方插件")
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("插件") {
                    Picker("", selection: $pluginID) {
                        Text("未选择").tag("")
                        ForEach(hostablePlugins, id: \.manifest.pluginUUID) { plugin in
                            Text(plugin.manifest.name).tag(plugin.manifest.pluginUUID)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: pluginID) { _, _ in
                        pluginActionUUID = ""
                        refreshDraftContext()
                    }
                }
                LabeledContent("动作") {
                    if let selected {
                        Picker("", selection: $pluginActionUUID) {
                            Text("未选择").tag("")
                            ForEach(selected.manifest.keypadActions, id: \.uuid) { action in
                                Text(action.name).tag(action.uuid)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: pluginActionUUID) { _, _ in refreshDraftContext() }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                if let stateCount = appModel.pluginHost.stateCount(pluginID: pluginID, actionUUID: pluginActionUUID) {
                    // stateCycleCount:手动轮换的重渲信号——setState 原地改实例,@Observable 观测不到,
                    // 读一次强制 body 重跑以刷新「当前第 X 态」
                    let _ = stateCycleCount
                    LabeledContent("状态") {
                        HStack(spacing: 8) {
                            let current = appModel.pluginHost.currentState(pluginID: pluginID, contextID: draftContextID) ?? 0
                            Text("\(stateCount) 态 · 按键自动轮换 · 当前第 \(current + 1) 态")
                                .foregroundStyle(.secondary)
                            if appModel.pluginHost.currentState(pluginID: pluginID, contextID: draftContextID) != nil {
                                Button("切换预览") {
                                    appModel.pluginHost.cycleState(pluginID: pluginID, contextID: draftContextID)
                                    stateCycleCount += 1
                                }
                                .help("手动切到下一态,设备键面即时预览(保存后按键也可自动轮换)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// 草稿实例身份维护:原插件动作未变复用原 contextID(实例跨保存稳定);新动作一次性生成新身份
    private func refreshDraftContext() {
        if case .plugin(let oldPlugin, let oldAction, let oldContext) = originalAction,
           oldPlugin == pluginID, oldAction == pluginActionUUID {
            draftContextID = oldContext
        } else if !pluginID.isEmpty, !pluginActionUUID.isEmpty {
            draftContextID = UUID().uuidString
        } else {
            draftContextID = ""
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
        // 含 guard 语句的 case 会让 switch 退化成语句形式,全表显式 return
        switch kind {
        case .none:
            return nil
        case .openApp, .openURL, .runShortcut, .shellScript, .appleScript, .hotkey:
            // 六种带参模板:组装口径与 TemplateConfigSheet 同源(KeyTemplate.assemble 单函数)
            guard let template = kind.templateKind else { return nil }
            return KeyTemplate.assemble(template, appPath: appPath, urlString: urlString,
                                        shortcutName: shortcutName, scriptText: scriptText,
                                        hotkeyKeyCode: hotkeyKeyCode, hotkeyModifiers: hotkeyModifiers)
        case .mediaKey:
            return .mediaKey(mediaKeyValue)
        case .plugin:
            return assembledPluginAction
        case .monitor:
            return .monitor(monitorCommand)
        case .stat:
            return .stat(statKind)
        case .gotoPageLegacy:
            return nil // 旧动作不可再组装(前往指定页的选择器已移除),保存即清除
        case .heatmap:
            return .keyboardHeatmap
        case .previousPage:
            return .previousPage
        case .nextPage:
            return .nextPage
        case .previousScene:
            return .previousScene
        case .nextScene:
            return .nextScene
        case .pageIndicator:
            return .pageIndicator
        case .screenOff:
            return .screenOff
        case .sleepGuard:
            return .sleepGuard
        }
    }

    /// 插件动作组装:contextID 来自草稿状态(原动作复用持久化身份;换动作在 onChange 时已定)
    private var assembledPluginAction: KeyAction? {
        guard !pluginID.isEmpty, !pluginActionUUID.isEmpty, !draftContextID.isEmpty else { return nil }
        return .plugin(pluginID: pluginID, actionUUID: pluginActionUUID, contextID: draftContextID)
    }

    /// 取消编辑:仅撤销草稿与 PI 预登记。不做任何 settings 清理——孤儿记录无害
    /// (无实例引用、字节级,卸载插件时 removeDocument 兜底);曾实证清理逻辑
    /// 会误删活的 context 记录(18:27 插桩),故永久移除
    private func cancelEdit() {
        appModel.pluginHost.clearPendingPI(contextID: draftContextID)
        dismiss()
    }

    /// 清除此键：动作 / 动效 / 标题 / 图标 / 模板占位全部清空，立即保存上屏（槽位 11 清「切换输入」用这个）
    private func clearKey() {
        var key = appModel.config.keyConfig(at: index)
        key.action = nil
        key.animation = nil
        key.title = ""
        key.iconPath = nil
        key.template = nil
        appModel.config.updateKey(key, at: index)
        appModel.applyKey(at: index)
        dismiss()
    }

    private func save() {
        appModel.config.updateKey(draftConfig, at: index)
        appModel.applyKey(at: index)
        dismiss()
    }
}
