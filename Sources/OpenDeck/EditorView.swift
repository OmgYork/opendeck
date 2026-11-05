import AppKit
import os
import StreamDockKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 主编辑器

/// 主窗口:玻璃工具栏(状态/亮度/操作)+ 键盘底座上的 18 键帽网格 + 编辑 Sheet。
struct EditorView: View {
    let appModel: AppModel

    private static let paletteLog = Logger(subsystem: "opendeck", category: "palette") // 仅拖放事件追踪;落键政策日志在 AppModel

    @State private var editingTarget: EditTarget?
    @State private var brightness: Double = 0
    @State private var showLayoutTuning = false
    @State private var showGlassCalibration = false
    @State private var showPluginManager = false
    @State private var showLogSheet = false
    @State private var dropTargetIndex: Int?
    /// 正在配置的模板磁贴(点调色盘模板磁贴弹出配置面板;保存进 AppModel.templateDrafts 就绪态)
    @State private var configuringTemplate: KeyTemplate?
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
        HStack(alignment: .top, spacing: 24) {
            // 左列:设备底座 + 翻页/场景导航(布局原样,原单列 VStack 平移进来)
            VStack(spacing: 18) {
                if appModel.officialAppRunning {
                    conflictBanner
                }
                HStack(alignment: .center, spacing: 12) {
                    chassis
                        .overlay(alignment: .trailing) { navTrailingOverlay }
                    if appModel.config.navStyle == .matrixRail {
                        railMatrixNav
                    }
                }
                // 以理想高度(=底座高度)布局本行:右缘轨的 maxHeight:.infinity 只在底座高度内
                // 展开、与底座等高——否则会被 VStack 的整窗高度提案拉成通天空轨
                .fixedSize(horizontal: false, vertical: true)
                if showGlassCalibration {
                    glassCalibrationBar
                }
                sceneNavBottom
                hint
            }
            // 右列:功能调色盘,固定停靠(不是浮层,不遮挡键位)
            FunctionPaletteView(
                appModel: appModel,
                onConfigureTemplate: { kind in
                    configuringTemplate = kind
                }
            )
            .onHover { inside in
                // 指针在调色盘内:滚动只作用于调色盘,不翻页(见 SwipePageMonitor.handle)
                swipeMonitor.isPointerOverPalette = inside
            }
        }
        // 内容固定 15 键,无需滚动(滚动条与滚动功能已移除);顶部对齐保持原视觉——
        // 键帽定尺后,全屏/大窗下键列同样不摊开,只是画布留白增多(官方 Stream Deck app 同款做法)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        // 按玻璃工具栏自动让位,这里只补一点呼吸空隙
        .padding(.top, 8)
        // 场景管理对话框挂整窗层:三种导航样式(经典/矩阵)共用同一套状态
        .confirmationDialog(
            "删除场景「\(deleteTargetName)」?",
            isPresented: $pageDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除(该场景全部页一并删除)", role: .destructive) {
                if let id = deleteTargetID { appModel.deleteScene(id: id) }
            }
            Button("取消", role: .cancel) { deleteTargetID = nil }
        }
        .alert("重命名场景", isPresented: $renameAlertShown) {
            TextField("场景名", text: $renameText)
            Button("好") {
                if let id = renameTargetID { appModel.config.renameScene(id: id, to: renameText) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty) // 空名:ConfigStore 会静默忽略,这里直接不给按
            Button("取消", role: .cancel) { renameTargetID = nil }
        }
        .sheet(isPresented: $pageBindingSheetShown) {
            if let id = pageBindingTargetID {
                SceneAppBindingSheet(appModel: appModel, sceneID: id)
            }
        }
        .toolbar { toolbar }
        .containerBackground(for: .window) {
            Color(nsColor: .windowBackgroundColor)
        }
        // 双列下限:底座 584 + 右缘轨 ~100(矩阵导航样式) + 间距 + 调色盘 344 + 左右留白 48
        .frame(minWidth: 1120, minHeight: 560)
        .task { appModel.start() }
        .onAppear {
            brightness = Double(appModel.config.config.brightness)
            // 设备未连接时 drawKey 只入缓存,连接校准时控制器会自动全量重画
            appModel.applyPageToDevice()
            swipeMonitor.onSwipe = { isHorizontal, direction in
                if isHorizontal {
                    appModel.switchScene(offset: direction)
                } else {
                    appModel.switchPage(offset: direction)
                }
            }
            swipeMonitor.start()
            appModel.editorWindowVisible = true
        }
        .onDisappear {
            swipeMonitor.end()
            appModel.editorWindowVisible = false
            // 关窗即评估联动;关窗瞬间 frontmostApplication 可能仍是自己且无系统事件兜底,
            // 故三连采样(+0.3s/+1s/+2s)覆盖结算竞态;评估幂等(目标即当前场景则 no-op)
            Task { @MainActor in
                for delay in [0.3, 1.0, 2.0] {
                    try? await Task.sleep(for: .seconds(delay))
                    appModel.autoSwitchPageForFrontmostApp()
                }
            }
        }
        .onChange(of: appModel.device.state) { _, state in
            if state == .running { appModel.applyPageToDevice() }
        }
        .modifier(ModalSwipeSuppression(
            monitor: swipeMonitor,
            editing: editingTarget != nil,
            layout: showLayoutTuning,
            manager: showPluginManager,
            binding: pageBindingSheetShown,
            template: configuringTemplate != nil,
            logs: showLogSheet
        ))
        .sheet(item: $editingTarget) { target in
            KeyEditView(index: target.index, appModel: appModel)
        }
        .sheet(item: $configuringTemplate) { kind in
            TemplateConfigSheet(
                kind: kind,
                initial: appModel.templateDrafts[kind],
                onSave: { config in
                    // 草稿持久化(config.templateDrafts);一次性消费在落键,手动清除走磁贴右键
                    appModel.setTemplateDraft(kind, config)
                }
            )
        }
        .sheet(isPresented: $showLayoutTuning) {
            LayoutTuningSheet(appModel: appModel)
        }
        .sheet(isPresented: $showPluginManager) {
            PluginManagerSheet(appModel: appModel)
        }
        .sheet(isPresented: $showLogSheet) {
            LogSheet(appModel: appModel)
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
                Toggle(isOn: $showGlassCalibration) {
                    Label("玻璃对位校准", systemImage: "scope")
                }
                Button {
                    showPluginManager = true
                } label: {
                    Label("插件管理…", systemImage: "puzzlepiece.extension")
                }
                Picker(selection: Binding(
                    get: { appModel.config.navStyle },
                    set: { appModel.config.navStyle = $0 }
                )) {
                    Text("导航样式:经典(芯片 + 页点)").tag(NavigationStyle.classic)
                    Text("导航样式:矩阵 · 下置").tag(NavigationStyle.matrixBelow)
                    Text("导航样式:矩阵 · 右缘").tag(NavigationStyle.matrixRail)
                } label: {
                    Label("导航样式", systemImage: "square.grid.3x3")
                }
                Picker(selection: Binding(
                    get: { appModel.config.autoScreenOffMinutes },
                    set: { appModel.setAutoScreenOffMinutes($0) }
                )) {
                    Text("自动熄屏:关").tag(0)
                    Text("自动熄屏:5 分钟").tag(5)
                    Text("自动熄屏:10 分钟").tag(10)
                    Text("自动熄屏:30 分钟").tag(30)
                    Text("自动熄屏:60 分钟").tag(60)
                } label: {
                    Label("自动熄屏", systemImage: "moon.zzz")
                }
                Toggle(isOn: Binding(
                    get: { appModel.config.sliderZeroBlacksKeys },
                    set: { appModel.setSliderZeroBlacksKeys($0) }
                )) {
                    Label("滑杆 0% 时键面涂黑", systemImage: "light.min")
                }
                Button {
                    appModel.device.screenOff()
                } label: {
                    Label("立即熄屏", systemImage: "moon.zzz.fill")
                }
                Button {
                    appModel.pluginHost.reviveRuntimes() // 死亡插件的人工复活入口
                    appModel.applyPageToDevice()
                } label: {
                    Label("重新应用到设备", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Button {
                    exportBackup()
                } label: {
                    Label("导出配置备份…", systemImage: "square.and.arrow.up")
                }
                Button {
                    importBackup()
                } label: {
                    Label("导入配置备份…", systemImage: "square.and.arrow.down")
                }
                Button {
                    NSWorkspace.shared.open(AppModel.autoBackupRoot)
                } label: {
                    Label("打开自动备份文件夹", systemImage: "shippingbox")
                }
                Divider()
                Button {
                    showLogSheet = true
                } label: {
                    Label("运行日志…", systemImage: "doc.text.magnifyingglass")
                }
                Divider()
                Button("退出 OpenDeck") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 配置备份(§6.29)

    /// 导出:SavePanel 选位置 → 整机打包。导出只读内存真相,对运行状态零影响
    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = Self.defaultBackupFileName()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                _ = try appModel.exportBackup(to: url)
            } catch {
                Self.porterAlert(style: .critical, text: "导出失败", detail: error.localizedDescription)
            }
        }
    }

    /// 导入:OpenPanel 选 zip → 校验暂存 → 确认弹窗 → 自重启生效(取消则清暂存)
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let summary = try appModel.stageBackupImport(from: url)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "导入这份备份?"
                alert.informativeText = """
                将替换当前全部配置与插件,重启后生效:
                · 场景 \(summary.sceneCount) 个 / 键位 \(summary.keyCount) 格
                · 插件 \(summary.pluginCount) 个
                · 插件参数文档 \(summary.settingsDocumentCount) 份\(summary.skippedSettingsFiles > 0 ? "(另有 \(summary.skippedSettingsFiles) 份损坏参数被跳过)" : "")
                """
                alert.addButton(withTitle: "退出并导入")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    ConfigPorter.relaunchAfterPendingImport()
                } else {
                    ConfigPorter.cancelPendingImport()
                }
            } catch {
                Self.porterAlert(style: .critical, text: "导入失败", detail: error.localizedDescription)
            }
        }
    }

    private static func defaultBackupFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "OpenDeck-backup-\(formatter.string(from: Date())).zip"
    }

    private static func porterAlert(style: NSAlert.Style, text: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = text
        alert.informativeText = detail
        alert.runModal()
    }

    /// 连接状态徽章
    private var statusPill: some View {
        let connected = appModel.device.state == .running
        // 熄屏/涂黑不再静默:Mac 端看得见设备为什么是黑的,菜单里也有「立即熄屏」的对称出口
        let screenOff = connected && appModel.device.isScreenOff
        let blacked = connected && !screenOff && appModel.device.keysBlacked
        return HStack(spacing: 7) {
            Circle()
                .fill(!connected ? Color.gray : screenOff || blacked ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: connected && !screenOff && !blacked ? .green.opacity(0.6) : .clear, radius: 3)
            Text(!connected ? "未连接设备"
                 : screenOff ? "已熄屏(按任意键唤醒)"
                 : blacked ? "键面已涂黑(亮度回拉恢复)"
                 : "Stream Dock 293V3")
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

    // MARK: 导航样式开关(经典 / 矩阵·下置 / 矩阵·右缘)

    /// 底座右缘悬浮层:仅经典样式挂页点胶囊(下置矩阵无右缘元素;右缘轨在 body 旁挂)
    @ViewBuilder
    private var navTrailingOverlay: some View {
        if appModel.config.navStyle == .classic {
            classicDotsOverlay
        }
    }

    /// 下方导航槽:经典 = 场景芯片栏;矩阵·下置 = A 矩阵;矩阵·右缘 = 无(导航在右缘轨)
    @ViewBuilder
    private var sceneNavBottom: some View {
        switch appModel.config.navStyle {
        case .classic: pageBar
        case .matrixBelow: matrixBelowNav
        case .matrixRail: EmptyView()
        }
    }

    /// 经典样式:玻璃胶囊内竖排圆点,当前页亮白;点击圆点直达;单页场景隐藏
    @ViewBuilder
    private var classicDotsOverlay: some View {
        if let info = appModel.config.currentPagePositionInScene, info.count > 1 {
            VStack(spacing: 6) {
                ForEach(0..<info.count, id: \.self) { position in
                    Circle()
                        .fill(position == info.position ? Color.white : Color.white.opacity(0.32))
                        .frame(width: position == info.position ? 8 : 6,
                               height: position == info.position ? 8 : 6)
                        .contentShape(Circle())
                        .onTapGesture { jumpToScenePage(position) }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .offset(x: 14)
            .animation(.snappy(duration: 0.25), value: info.position)
        }
    }

    private func jumpToScenePage(_ position: Int) {
        guard let id = appModel.config.pageIDInCurrentScene(position: position) else { return }
        appModel.switchPage(to: id)
    }

    // MARK: 页面栏

    private var currentSceneID: UUID? { appModel.config.currentSceneID }

    /// 「+ 添加场景」虚位芯片(经典芯片栏与两种矩阵共用)
    var addSceneChip: some View {
        Button {
            appModel.addScene()
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
        .help("添加场景")
    }

    /// 场景芯片栏(经典样式):每场景一枚芯片,点按切换;+ 追加场景;芯片右键管理(场景联动/复制/加页/重命名/删除)
    private var pageBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(appModel.config.config.scenes.enumerated()), id: \.element.id) { offset, scene in
                sceneChip(offset: offset, scene: scene)
            }
            addSceneChip
        }
        .padding(.horizontal, 4)
        .animation(.snappy(duration: 0.25), value: appModel.config.currentSceneIndex)
    }

    private var deleteTargetName: String {
        guard let id = deleteTargetID,
              let index = appModel.config.indexOfScene(id: id)
        else { return "" }
        return appModel.config.config.scenes[index].name
    }

    /// 单枚场景芯片:点按切换;当前场景高亮;右键管理与场景联动(经典栏与两种矩阵共用)
    func sceneChip(offset: Int, scene: DeckScene) -> some View {
        let isCurrent = scene.id == currentSceneID
        return Button {
            if let id = scene.id, !isCurrent { appModel.switchScene(to: id) }
        } label: {
            // 当前场景的芯片亮出名字(信息可见性);其余芯片保持编号紧凑
            HStack(spacing: 5) {
                Text("\(offset + 1)")
                if isCurrent {
                    Text(scene.name)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(isCurrent ? .primary : .secondary)
            .padding(.horizontal, isCurrent ? 9 : 0)
            .frame(minWidth: 32, minHeight: 30)
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
        .help("\(scene.name) · \(scene.pages.count) 页")
        .contextMenu {
            Button("前台应用自动切换…") {
                pageBindingTargetID = scene.id
                pageBindingSheetShown = true
            }
            Button("添加页") {
                if let id = scene.id { appModel.addPage(toScene: id) }
            }
            if isCurrent {
                // 圆点页此前只能加不能删(误触「添加页」永久留痕);主页(第 1 页)按设计不可删
                Button("删除当前页(圆点)", role: .destructive) {
                    appModel.deletePageInCurrentScene(at: appModel.config.currentPageIndex)
                }
                .disabled(appModel.config.currentPageIndex == 0 || scene.pages.count < 2)
                .help(appModel.config.currentPageIndex == 0 ? "主页不可删除" : "删除正在查看的这页圆点")
                // 圆点排序此前不可调:加多了只能靠删了重加
                Button("当前页左移") {
                    appModel.sceneRouter.moveCurrentPage(offset: -1)
                }
                .disabled(appModel.config.currentPageIndex == 0)
                Button("当前页右移") {
                    appModel.sceneRouter.moveCurrentPage(offset: 1)
                }
                .disabled(appModel.config.currentPageIndex >= scene.pages.count - 1)
            }
            Button("重命名") {
                renameTargetID = scene.id
                renameText = scene.name
                renameAlertShown = true
            }
            // 场景排序此前不可调:只能删了按顺序重建
            Button("左移") {
                appModel.sceneRouter.moveScene(offset: -1)
            }
            .disabled(offset == 0)
            Button("右移") {
                appModel.sceneRouter.moveScene(offset: 1)
            }
            .disabled(offset >= appModel.config.sceneCount - 1)
            Button("删除", role: .destructive) {
                guard appModel.config.sceneCount > 1 else { return }
                deleteTargetID = scene.id
                pageDeleteConfirm = true
            }
            .disabled(appModel.config.sceneCount < 2)
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
            // 底座贴合键列:LazyVGrid 容器默认撑满提案宽度(固定轨道居中其中),
            // 会让暗色底座在宽窗下比键列宽出一大截;定尺后按理想宽度收缩
            .fixedSize(horizontal: true, vertical: false)
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
                let key = AppModel.resolvedKeyConfig(at: index, config: appModel.config)
                // 放置目标挂在 ZStack 而非 Button 上：Button 自身吃掉手势，
                // 直接往 Button 上挂 dropDestination 在合成输入下收不到落点
                ZStack {
                    Button {
                        // 保留槽(仅导航 14/15):全页保留,不开放编辑(统计键已动作化,不再占 6/7/8)
                        guard AppModel.reservedSlot(at: index) == nil else { return }
                        editingTarget = EditTarget(index: index)
                    } label: {
                        KeycapView(
                            config: key,
                            remotePressed: appModel.pressedKeyIndices.contains(index),
                            slot: appModel.keyImageSlots[index],
                            staticFrame: appModel.animationPreviewFrame(for: key),
                            pluginMissing: appModel.pluginHost.isPluginMissing(key.action)
                        )
                    }
                    .buttonStyle(KeycapButtonStyle())
                    if dropTargetIndex == index {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: String.self) { items, _ in
                    // 用纯文本承载载荷（格式见 FunctionPaletteCatalog 头注释）：自定义 UTType
                    // 在宿主 NSView 上不保证被接受，而 public.utf8-plain-text 投放链路最稳
                    guard let raw = items.first,
                          AppModel.reservedSlot(at: index) == nil else {
                        Self.paletteLog.info("palette drop rejected at \(index, privacy: .public)")
                        return false
                    }
                    dropTargetIndex = nil
                    Self.paletteLog.info("palette drop \(raw, privacy: .public) → key \(index, privacy: .public)")
                    bindPayload(raw, at: index)
                    return true
                } isTargeted: { targeted in
                    // 保留槽不亮拖放圈:亮白圈再静默拒绝是纯挫败感
                    if targeted, AppModel.reservedSlot(at: index) != nil { return }
                    if targeted { Self.paletteLog.info("palette drop target entered \(index, privacy: .public)") }
                    dropTargetIndex = targeted ? index : (dropTargetIndex == index ? nil : dropTargetIndex)
                }
                .help(AppModel.reservedSlot(at: index) == nil
                      ? "编辑第 \(index + 1) 键"
                      : "保留键(不可编辑)")
                .contextMenu {
                    if AppModel.reservedSlot(at: index) == nil {
                        Button("复制此键") {
                            appModel.copyKey(at: index)
                        }
                        Button("粘贴到此处") {
                            appModel.pasteKey(at: index)
                        }
                        .disabled(appModel.keyClipboard == nil)
                        Divider()
                        Button("清除此键", role: .destructive) {
                            appModel.clearKeyFromContextMenu(at: index)
                        }
                        .disabled(key.action == nil && key.title.isEmpty && key.iconPath == nil
                                  && key.animation == nil && key.template == nil)
                    }
                }
            }
        }
    }

    // 5×3 全主键;键帽定尺 100pt(与设备键面 1:1),窗口缩放不改变键帽大小
    private static let gridColumns: [GridItem] =
        Array(repeating: GridItem(.fixed(100), spacing: 12), count: StreamDock293S.columns)

    /// 调色盘落下/点选:落键政策在 AppModel.bindPayload(复刻/草稿消费/插件实例政策),视图只转发
    private func bindPayload(_ raw: String, at index: Int) {
        appModel.bindPayload(raw, at: index)
    }

    // MARK: - 玻璃对位校准(实时预览区内联)

    /// 与键帽底座同宽(5×100 + 4×12 + 2×18 = 584),贴在预览下方实时调参
    private var glassCalibrationBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Label("玻璃对位校准", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                Text("拖动即时下发设备,软件镜像不偏移")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复位") { appModel.setGlassOffset(.zero) }
                    .controlSize(.small)
                Button("收起") { showGlassCalibration = false }
                    .controlSize(.small)
            }
            HStack(spacing: 16) {
                glassSlider("X(正=右)", keyPath: \.x, range: -12...12, suffix: "")
                glassSlider("Y(正=上)", keyPath: \.y, range: -12...12, suffix: "")
                glassSlider("缩放", keyPath: \.zoom, range: 80...120, suffix: "%")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 584)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.34), .black.opacity(0.20)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }
        }
    }

    private func glassSlider(_ title: String, keyPath: WritableKeyPath<GlassOffset, Int>,
                             range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(appModel.glassOffset[keyPath: keyPath])\(suffix)")
                    .font(.caption.monospacedDigit())
            }
            Slider(value: glassBinding(keyPath), in: range, step: 1)
                .controlSize(.small)
        }
    }

    /// 滑杆是 Double,配置是整数像素/百分比:四舍五入后写回并即时下发
    private func glassBinding(_ keyPath: WritableKeyPath<GlassOffset, Int>) -> Binding<Double> {
        Binding(
            get: { Double(appModel.glassOffset[keyPath: keyPath]) },
            set: { newValue in
                var next = appModel.glassOffset
                next[keyPath: keyPath] = Int(newValue.rounded())
                appModel.setGlassOffset(next)
            }
        )
    }

    private var hint: some View {
        Text("单击编辑 · 右键复制/粘贴/清除 · 拖调色盘磁贴落键")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// Sheet 的 item 包装(Int 本身不携带语义,包一层可读性更好)
struct EditTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - 触控板手势(应用内事件监听)

/// 两级手势:垂直扫=场景内翻页,水平扫=切场景。
/// 机制:NSEvent 本地监听(AppKit 派发给本应用的滚动事件先经此处)。
/// 步进保证:触控板精确手势以「手指接触周期」(phase began→changed→ended)为单位,
/// 周期内至多步进 1,手指离开后的惯性滚动(momentumPhase)全部吞掉——
/// 不论速度多快、行程多长,一次扫动恰好步进 1。传统滚轮(无相位)一格一步 + 0.35s 冷却防连翻。
// MARK: - 模态滑动抑制


// MARK: - 全局热键捕获

/// 录制期间用 NSEvent local monitor 截获本应用全部按键事件:
/// 比 NSView keyDown 可靠(不受焦点状态与菜单键等价拦截影响),且无需辅助功能权限。
/// 生命周期纪律:start 前必 end;捕获到组合键或 ⎋ 后立即 end;视图消失兜底 end,
/// 确保 monitor 绝不会在录制之外吞键。
// MARK: - 键面颜色(UI 侧)


/// NSOpenPanel 的最小封装;runModal 在主线程阻塞是 AppKit 模态的标准用法
// MARK: - 页面场景联动设置

