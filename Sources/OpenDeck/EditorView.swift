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
            }
            Button("重命名") {
                renameTargetID = scene.id
                renameText = scene.name
                renameAlertShown = true
            }
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

/// 应用图标 → 键面底图 PNG(落盘缓存:~/Library/Application Support/OpenDeck/app-icons/)。
/// 缓存键 = bundleID(稳定可读),无 bundleID 时退回转义路径;同一 app 只渲一次。
/// 注意:NSWorkspace.icon 会带 Finder 同款文件状态角标(隔离/替身等)——与用户在 Finder 看到的一致。
// MARK: - 模板磁贴配置面板（调色盘）

/// 点击调色盘里的模板磁贴弹出:配参数 → 保存为就绪态(AppModel.templateDrafts,会话内存)
/// → 拖拽磁贴到键位即完整键;**一次性**——落键即消费草稿,磁贴复原;再点磁贴 = 重新配置。
/// 只收 6 种带参模板;复用 KeyEditView 同款捕获组件(HotkeyCaptureField/FilePicker),
/// 参数口径与 KeyEditView.assembledAction 一致(空参不成动作,含空脚本)。
private struct TemplateConfigSheet: View {
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

