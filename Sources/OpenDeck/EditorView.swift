import AppKit
import StreamDockKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 主编辑器

/// 主窗口:玻璃工具栏(状态/亮度/操作)+ 键盘底座上的 18 键帽网格 + 编辑 Sheet。
struct EditorView: View {
    let appModel: AppModel

    @State private var editingTarget: EditTarget?
    @State private var brightness: Double = 0
    @State private var showLayoutTuning = false
    @State private var showPluginManager = false
    @State private var deleteTargetID: UUID?
    @State private var pageDeleteConfirm = false
    @State private var renameTargetID: UUID?
    @State private var renameAlertShown = false
    @State private var renameText = ""
    @State private var sceneTargetID: UUID?
    @State private var sceneAlertShown = false
    @State private var sceneText = ""
    @State private var pageBindingTargetID: UUID?
    @State private var pageBindingSheetShown = false
    @State private var swipeMonitor = SwipePageMonitor()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if appModel.officialAppRunning {
                    conflictBanner
                }
                chassis
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { swipeMonitor.gridFrame = geo.frame(in: .global) }
                                .onChange(of: geo.frame(in: .global)) { _, frame in
                                    swipeMonitor.gridFrame = frame
                                }
                        }
                    )
                pageBar
                hint
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            // 滚动视图已按玻璃工具栏自动让位,这里只补一点呼吸空隙
            .padding(.top, 8)
        }
        .toolbar { toolbar }
        .containerBackground(for: .window) {
            Color(nsColor: .windowBackgroundColor)
        }
        .frame(minWidth: 760, minHeight: 560)
        .task { appModel.start() }
        .onAppear {
            brightness = Double(appModel.config.config.brightness)
            // 设备未连接时 drawKey 只入缓存,连接校准时控制器会自动全量重画
            appModel.applyPageToDevice()
            swipeMonitor.onSwipe = { isHorizontal, direction in
                if isHorizontal {
                    appModel.switchScene(offset: direction)
                } else {
                    appModel.switchPage(offset: direction, withinScene: true)
                }
            }
            swipeMonitor.start()
            appModel.editorWindowVisible = true
        }
        .onDisappear {
            swipeMonitor.end()
            appModel.editorWindowVisible = false
        }
        .onChange(of: appModel.device.state) { _, state in
            if state == .running { appModel.applyPageToDevice() }
        }
        .sheet(item: $editingTarget) { target in
            KeyEditView(index: target.index, appModel: appModel)
        }
        .sheet(isPresented: $showLayoutTuning) {
            LayoutTuningSheet(appModel: appModel)
        }
        .sheet(isPresented: $showPluginManager) {
            PluginManagerSheet(appModel: appModel)
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // 工具栏项一律不自绘玻璃(系统已给单层玻璃,自绘会叠成两层)
        ToolbarItem(placement: .principal) { statusPill }
        ToolbarItem(placement: .primaryAction) { brightnessControl }
        // ToolbarSpacer:分隔玻璃组,让亮度与菜单各成一体
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showLayoutTuning = true
                } label: {
                    Label("亮度布局调参…", systemImage: "slider.horizontal.3")
                }
                Button {
                    showPluginManager = true
                } label: {
                    Label("插件管理…", systemImage: "puzzlepiece.extension")
                }
                Picker(selection: Binding(
                    get: { appModel.config.autoScreenOffMinutes },
                    set: { appModel.config.autoScreenOffMinutes = $0 }
                )) {
                    Text("自动熄屏:关").tag(0)
                    Text("自动熄屏:5 分钟").tag(5)
                    Text("自动熄屏:10 分钟").tag(10)
                    Text("自动熄屏:30 分钟").tag(30)
                    Text("自动熄屏:60 分钟").tag(60)
                } label: {
                    Label("自动熄屏", systemImage: "moon.zzz")
                }
                Button {
                    appModel.applyPageToDevice()
                } label: {
                    Label("重新应用到设备", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Button("帮助") {}
                Divider()
                Button("退出 OpenDeck") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// 连接状态徽章
    private var statusPill: some View {
        let connected = appModel.device.state == .running
        return HStack(spacing: 7) {
            Circle()
                .fill(connected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .shadow(color: connected ? .green.opacity(0.6) : .clear, radius: 3)
            Text(connected ? "Stream Dock 293V3" : "未连接设备")
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// 亮度:点击整个胶囊切换 自适应/手动;布局参数由「布局调参」面板实时驱动
    private var brightnessControl: some View {
        let layout = appModel.config.layout
        return HStack(spacing: layout.gap) {
            Image(systemName: !appModel.followSystemBrightness && brightness < 15 ? "sun.min" : "sun.max.fill")
                .foregroundStyle(.yellow)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: appModel.followSystemBrightness)

            // 内容槽:定宽,「自适应」与滑杆 blurReplace 交叉溶解
            ZStack {
                if appModel.followSystemBrightness {
                    Text("自适应")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Slider(value: Binding(
                        get: { brightness },
                        set: { newValue in
                            // 自定义 Binding:只有真实拖动走 setBrightness(程序性赋值直接写 @State,不经过这里)
                            brightness = newValue
                            appModel.setBrightness(Int(newValue))
                        }
                    ), in: 0...100) { editing in
                        if !editing { appModel.commitBrightness() }
                    }
                    .frame(width: layout.slot)
                    // macOS 滑杆轨道两侧自带 ~10pt 内缩,负边距抵消,让轨道视觉填满槽位
                    .padding(.horizontal, -12)
                }
            }
            .frame(width: layout.slot)
            .transition(.blurReplace)
        }
        .padding(.leading, layout.lead)
        .padding(.trailing, layout.trail)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            appModel.setFollowSystemBrightness(!appModel.followSystemBrightness)
        }
        .help(appModel.followSystemBrightness ? "正在自适应 MacBook 亮度,点击改为手动" : "点击切换:亮度自适应 MacBook")
        .animation(.smooth(duration: 0.35), value: appModel.followSystemBrightness)
        .animation(.linear(duration: 0.08), value: layout)
        .onChange(of: appModel.config.brightness) { _, newValue in
            // 外部变化(跟随镜像/菜单栏)同步进本地;直接写 @State 不触发上面的用户路径
            if Int(brightness) != newValue {
                brightness = Double(newValue)
            }
        }
    }

    // MARK: 页面栏

    private var currentPageID: UUID? { appModel.config.currentPage.id }

    /// 多页面切换栏:每页一枚芯片平铺,点按切换;右键菜单重命名/删除;+ 追加
    private var pageBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(appModel.config.config.pages.enumerated()), id: \.element.id) { offset, page in
                pageChip(offset: offset, page: page)
            }
            Button {
                appModel.addPage()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 30)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("添加页面")
        }
        .padding(.horizontal, 4)
        .confirmationDialog(
            "删除页面「\(deleteTargetName)」?",
            isPresented: $pageDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除(该页按键配置一并删除)", role: .destructive) {
                if let id = deleteTargetID { appModel.deletePage(id: id) }
            }
            Button("取消", role: .cancel) { deleteTargetID = nil }
        }
        .alert("重命名页面", isPresented: $renameAlertShown) {
            TextField("页面名", text: $renameText)
            Button("好") {
                if let id = renameTargetID { appModel.config.renamePage(id: id, to: renameText) }
            }
            Button("取消", role: .cancel) { renameTargetID = nil }
        }
        .alert("所属场景(同场景的页归为一组,垂直扫动在其内翻页)", isPresented: $sceneAlertShown) {
            TextField("场景名", text: $sceneText)
            Button("好") {
                if let id = sceneTargetID { appModel.config.setSceneName(id: id, to: sceneText) }
            }
            Button("取消", role: .cancel) { sceneTargetID = nil }
        }
        .sheet(isPresented: $pageBindingSheetShown) {
            if let id = pageBindingTargetID {
                PageAppBindingSheet(appModel: appModel, pageID: id)
            }
        }
    }

    private var deleteTargetName: String {
        guard let id = deleteTargetID,
              let index = appModel.config.indexOfPage(id: id)
        else { return "" }
        return appModel.config.config.pages[index].name
    }

    /// 单枚页面芯片:点按切换;当前页高亮;右键重命名/删除
    private func pageChip(offset: Int, page: Page) -> some View {
        let isCurrent = page.id == currentPageID
        return Button {
            if let id = page.id, !isCurrent { appModel.switchPage(to: id) }
        } label: {
            Text("\(offset + 1)")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .frame(width: 32, height: 30)
                .background(
                    Color.primary.opacity(isCurrent ? 0.14 : 0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isCurrent ? .tertiary : .quaternary, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("\(page.name) · 场景:\(page.sceneName ?? "默认场景")")
        .contextMenu {
            Button("所属场景…") {
                sceneTargetID = page.id
                sceneText = page.sceneName ?? "默认场景"
                sceneAlertShown = true
            }
            Button("前台应用自动切换…") {
                pageBindingTargetID = page.id
                pageBindingSheetShown = true
            }
            Button("复制页面") {
                if let id = page.id { appModel.duplicatePage(id: id) }
            }
            Button("重命名…") {
                renameTargetID = page.id
                renameText = page.name
                renameAlertShown = true
            }
            Button("删除…", role: .destructive) {
                guard appModel.config.pageCount > 1 else { return }
                deleteTargetID = page.id
                pageDeleteConfirm = true
            }
            .disabled(appModel.config.pageCount < 2)
        }
    }

    // MARK: 冲突警示

    private var conflictBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("官方 StreamDock 正在运行")
                    .font(.callout.weight(.semibold))
                Text("两个管理器会争抢设备,面板图标可能来回闪烁")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出它") {
                appModel.quitOfficialApp()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.22)), in: .rect(cornerRadius: 16))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 键盘底座

    /// 设备底座:暗色实体面板承载键帽网格,暗示「这里就是那台硬件」。
    /// 用 background(而非 Shape.overlay)承载体积——后者在 ScrollView 里拿不到高度会塌陷
    private var chassis: some View {
        keyGrid
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.black.opacity(0.38), .black.opacity(0.22)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.30), radius: 16, y: 6)
            }
    }

    private var keyGrid: some View {
        LazyVGrid(columns: Self.gridColumns, spacing: 12) {
            ForEach(0..<(StreamDock293S.rows * StreamDock293S.columns), id: \.self) { index in
                Button {
                    editingTarget = EditTarget(index: index)
                } label: {
                    KeycapView(
                        config: appModel.config.keyConfig(at: index),
                        remotePressed: appModel.pressedKeyIndices.contains(index)
                    )
                }
                .buttonStyle(KeycapButtonStyle())
                .help("编辑第 \(index + 1) 键")
            }
        }
    }

    // 5×3 全主键
    private static let gridColumns: [GridItem] =
        Array(repeating: GridItem(.flexible(), spacing: 12), count: StreamDock293S.columns)

    private var hint: some View {
        Text("单击键帽编辑,保存后立即上屏")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// Sheet 的 item 包装(Int 本身不携带语义,包一层可读性更好)
struct EditTarget: Identifiable {
    let index: Int
    var id: Int { index }
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
    /// 原动作:同键保存同插件动作时复用 contextID(实例身份跨保存稳定)
    private let originalAction: KeyAction?

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
    @State private var pluginID: String
    @State private var pluginActionUUID: String
    @State private var gotoPageID: UUID?

    init(index: Int, appModel: AppModel) {
        self.index = index
        self.appModel = appModel
        let key = appModel.config.keyConfig(at: index)
        originalAction = key.action
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
        var pluginID = ""
        var pluginActionUUID = ""
        var gotoPageID: UUID?
        switch key.action {
        case .openApp(let path): kind = .openApp; appPath = path
        case .openURL(let url): kind = .openURL; urlString = url
        case .runShortcut(let name): kind = .runShortcut; shortcutName = name
        case .shellScript(let script): kind = .shellScript; scriptText = script
        case .appleScript(let script): kind = .appleScript; scriptText = script
        case .hotkey(let code, let mods): kind = .hotkey; keyCode = code; modifiers = mods
        case .mediaKey(let name): kind = .mediaKey; mediaKey = name
        case .plugin(let id, let actionUUID, _):
            kind = .plugin
            pluginID = id
            pluginActionUUID = actionUUID
        case .previousPage: kind = .previousPage
        case .nextPage: kind = .nextPage
        case .previousScene: kind = .previousScene
        case .nextScene: kind = .nextScene
        case .gotoPage(let pageID): kind = .gotoPage; gotoPageID = pageID
        case .pageIndicator: kind = .pageIndicator
        case .screenOff: kind = .screenOff
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
        _pluginID = State(initialValue: pluginID)
        _pluginActionUUID = State(initialValue: pluginActionUUID)
        _gotoPageID = State(initialValue: gotoPageID)
    }

    /// 草稿状态组装出的键配置——live 预览与保存共用,保证「所见即所得」
    private var draftConfig: KeyConfig {
        KeyConfig(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            backgroundColorHex: normalizedColorHex,
            iconPath: iconPath,
            action: assembledAction
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
        .frame(width: 520)
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
        case .previousPage:
            LabeledContent("说明") { Text("在当前场景内循环切到上一页").foregroundStyle(.secondary) }
        case .nextPage:
            LabeledContent("说明") { Text("在当前场景内循环切到下一页").foregroundStyle(.secondary) }
        case .previousScene:
            LabeledContent("说明") { Text("循环切到上一场景(落到其第一页)").foregroundStyle(.secondary) }
        case .nextScene:
            LabeledContent("说明") { Text("循环切到下一场景(落到其第一页)").foregroundStyle(.secondary) }
        case .gotoPage:
            LabeledContent("目标页面") {
                Picker("", selection: $gotoPageID) {
                    Text("未选择").tag(UUID?.none)
                    ForEach(appModel.config.config.pages, id: \.id) { page in
                        if let id = page.id {
                            Text(page.name).tag(UUID?.some(id))
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        case .pageIndicator:
            LabeledContent("说明") { Text("键面实时显示当前页码(N/M),随页面切换自动刷新").foregroundStyle(.secondary) }
        case .screenOff:
            LabeledContent("说明") { Text("面板黑屏待机,按任意键唤醒(该次按压不触发动作)").foregroundStyle(.secondary) }
        }
    }

    /// 插件动作:已装 Node 插件 → 其 Keypad 型动作 两级选择
    private var pluginActionForm: some View {
        let nodePlugins = appModel.pluginHost.installedPlugins.filter { $0.manifest.family.isNode }
        let selected = nodePlugins.first { $0.manifest.pluginUUID == pluginID }
        return Group {
            if nodePlugins.isEmpty {
                LabeledContent("说明") {
                    Text("尚未安装插件。请从菜单栏「⋯ → 插件管理…」安装 .sdPlugin 或导入官方插件")
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("插件") {
                    Picker("", selection: $pluginID) {
                        Text("未选择").tag("")
                        ForEach(nodePlugins, id: \.manifest.pluginUUID) { plugin in
                            Text(plugin.manifest.name).tag(plugin.manifest.pluginUUID)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: pluginID) { _, _ in pluginActionUUID = "" }
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
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("说明") {
                    Text("动作参数面板(Property Inspector)将在 M3 提供;直播/录制等动作开箱即用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        case .plugin:
            assembledPluginAction
        case .previousPage:
            .previousPage
        case .nextPage:
            .nextPage
        case .previousScene:
            .previousScene
        case .nextScene:
            .nextScene
        case .gotoPage:
            gotoPageID.map { .gotoPage(pageID: $0) }
        case .pageIndicator:
            .pageIndicator
        case .screenOff:
            .screenOff
        }
    }

    /// 插件动作组装:同键保存同一动作 → 复用原 contextID;换动作 → 生成新实例
    private var assembledPluginAction: KeyAction? {
        guard !pluginID.isEmpty, !pluginActionUUID.isEmpty else { return nil }
        let contextID: String
        if case .plugin(let oldPlugin, let oldAction, let oldContext) = originalAction,
           oldPlugin == pluginID, oldAction == pluginActionUUID {
            contextID = oldContext
        } else {
            contextID = UUID().uuidString
        }
        return .plugin(pluginID: pluginID, actionUUID: pluginActionUUID, contextID: contextID)
    }

    private func save() {
        appModel.config.updateKey(draftConfig, at: index)
        appModel.applyKey(at: index)
        dismiss()
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
    case gotoPage
    case pageIndicator
    case screenOff
    case plugin

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
        case .previousPage: "上一页"
        case .nextPage: "下一页"
        case .previousScene: "上一场景"
        case .nextScene: "下一场景"
        case .gotoPage: "前往页面"
        case .pageIndicator: "页面指示"
        case .screenOff: "熄屏"
        case .plugin: "插件动作"
        }
    }
}

// MARK: - 触控板横扫切页

/// app 本地 scrollWheel 监听:仅网格区内的水平主导滚动参与;一次手势(事件间隔 <0.25s)
/// 最多翻 1 页,快扫的动量尾流不会连翻。自然滚动方向:双指左扫 = 下一页。
@MainActor
private final class SwipePageMonitor {
    private var token: Any?
    /// 双轴独立累积与消费标记:一次手势同一轴至多触发一次
    private var horizontalAccumulated: CGFloat = 0
    private var verticalAccumulated: CGFloat = 0
    private var horizontalConsumed = false
    private var verticalConsumed = false
    private var lastGestureEventAt = Date.distantPast
    /// 阈值:累积滚动量达到即触发(触控板一指行程约 10–30)
    private let threshold: CGFloat = 30
    /// 网格底座的全局窗口坐标(由 EditorView 的 GeometryReader 实时回填);nil = 未就绪不拦截
    var gridFrame: CGRect?
    /// 回调:isHorizontal(水平=切场景/垂直=场景内翻页)+ 方向(+1 下一/-1 上一)
    var onSwipe: ((_ isHorizontal: Bool, _ direction: Int) -> Void)?

    func start() {
        end()
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func end() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
        horizontalAccumulated = 0
        verticalAccumulated = 0
        horizontalConsumed = false
        verticalConsumed = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let horizontalDominant = abs(dx) > abs(dy)
        // 主轴判定:两轴分量都不足 1 的抖动直接放行
        guard horizontalDominant || abs(dy) >= 1 else { return event }
        // 空间门控:光标不在网格区内,扫动不参与切页。
        // 坐标系陷阱:NSEvent.mouseLocation 是屏幕坐标(左下原点),SwiftUI .global 是左上原点,y 须翻转
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let mouse = NSEvent.mouseLocation
        guard let frame = gridFrame,
              frame.contains(CGPoint(x: mouse.x, y: screenHeight - mouse.y))
        else { return event }
        // 手势切分:事件静默 >0.25s 视为新一次扫动,双轴累积与消费标记全部复位
        let now = Date()
        if now.timeIntervalSince(lastGestureEventAt) > 0.25 {
            horizontalAccumulated = 0
            verticalAccumulated = 0
            horizontalConsumed = false
            verticalConsumed = false
        }
        lastGestureEventAt = now

        if horizontalDominant {
            guard !horizontalConsumed else { return nil }
            horizontalAccumulated += dx
            guard abs(horizontalAccumulated) >= threshold else { return nil }
            horizontalConsumed = true
            // 自然滚动:双指左扫 deltaX 为正 = 看右侧内容 = 下一场景
            let direction = horizontalAccumulated > 0 ? 1 : -1
            horizontalAccumulated = 0
            onSwipe?(true, direction)
            return nil
        }
        guard !verticalConsumed else { return nil }
        verticalAccumulated += dy
        guard abs(verticalAccumulated) >= threshold else { return nil }
        verticalConsumed = true
        // 自然滚动:双指上扫 deltaY 为正 = 看下方内容 = 场景内下一页
        let direction = verticalAccumulated > 0 ? 1 : -1
        verticalAccumulated = 0
        onSwipe?(false, direction)
        return nil
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
enum HotkeySymbols {
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

// MARK: - 键面颜色(UI 侧)

/// 键面 hex 颜色的 UI 侧解析。
/// StreamDockKit 内部的 HexColor 未导出,且 UI 预览(Color)与设备渲染(CGImage)
/// 所需的类型不同,这里独立实现并用与 IconRenderer 相同的亮度阈值保证观感一致。
struct KeyPalette {
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


// MARK: - 页面场景联动设置

/// 前台应用自动切换:每页最多绑 3 个应用;可设为默认页
private struct PageAppBindingSheet: View {
    let appModel: AppModel
    let pageID: UUID

    @Environment(\.dismiss) private var dismiss
    private static let apps = AppModel.installedApps()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("当 OpenDeck 编辑器窗口关闭且下列应用程序位于前台时,自动切换到本页。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("绑定的应用程序") {
                    ForEach(0..<3, id: \.self) { slot in
                        LabeledContent("应用程序 \(slot + 1)") {
                            Picker("", selection: binding(for: slot)) {
                                Text("无").tag(String?.none)
                                ForEach(Self.apps, id: \.bundleID) { app in
                                    Text(app.name).tag(String?.some(app.bundleID))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }
                    }
                }
                Section {
                    Toggle("设为默认页面(前台应用无绑定时显示本页)", isOn: defaultBinding)
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
    }

    private func binding(for slot: Int) -> Binding<String?> {
        Binding(
            get: { appModel.config.pageAppBinding(id: pageID, slot: slot) },
            set: { appModel.config.setPageAppBinding(id: pageID, slot: slot, bundleID: $0) }
        )
    }

    private var defaultBinding: Binding<Bool> {
        Binding(
            get: { appModel.config.config.defaultPageID == pageID },
            set: { appModel.config.setDefaultPage(id: $0 ? pageID : nil) }
        )
    }
}
