import SwiftUI

// MARK: - 功能调色盘（编辑器右列固定停靠面板）
//
// 由「显示器功能托盘」泛化而来：全动作类型的统一拖拽/点选源，显示器只是其中一格。
// 2026-11-01 v5：按用户反馈取消浮动 deco——不再是悬浮在键位上方的独立层，
// 而是嵌入编辑器布局的固定右列（不遮挡键位、不可拖动、无收起态），内部滚动。
// v6：配色与编辑器统一——浅色材质卡片替代浮层时代的深色胶囊，
// 磁贴底色改 KeyConfig 默认色（与落到空槽位的实际键面一致）。
// v7：分类导航也磁贴化——顶部五个分类页签磁贴（点选切换、页签内滚动），
// 替代折叠文本分类头；折叠文本头只剩显示器分类内部的子分组在用。
// v8：点选绑定（点磁贴→点键位）删除，拖拽是唯一放置手势；
// 模板磁贴改为点击弹配置面板 → 保存为就绪态（AppModel.templateDrafts，会话内存）
// → 拖拽落键即完整键；**一次性**——落键即消费草稿，磁贴复原回占位态。
// v10：显示器分类撤「自定义/复合」小节、系统分类撤键盘热力图磁贴
// （分别由自定义页签的槽位镜像与槽 13 实键覆盖）。
// 顶层五分类——显示器（复合 + 画面/游戏/音频/输入，二级折叠）+
// 翻页/场景 + 媒体控制 + 系统 + 模板（待配置）；磁贴 = **真实键帽渲染**（KeycapView，
// 100pt 与编辑器槽位 1:1，复合磁贴直接显示动效帧，拖拽跟随图同源）；
// 模板磁贴落「待配置」占位键（KeycapView 虚线描边提示）；
// 指针悬停时滚动只作用于调色盘（由 EditorView 的 onHover 门控 SwipePageMonitor）。
// 载荷（拖拽/点选统一）：FunctionPaletteCatalog.item(forPayload:) 唯一解析，
// 格式见 FunctionPaletteCatalog.swift 头注释。

struct FunctionPaletteView: View {
    let appModel: AppModel
    /// 点模板磁贴 → 弹出配置面板（EditorView 持有 sheet 状态与 ModalSwipeSuppression）
    var onConfigureTemplate: (KeyTemplate) -> Void = { _ in }

    /// 当前页签（分类磁贴的 key；默认显示器——最常用）
    @State private var selectedCategory = "monitor"
    /// 折叠的显示器子分组 key（默认：自定义/复合展开，四个命令组折叠）
    @State private var collapsedSections: Set<String> = ["picture", "game", "audio", "input"]

    private let tileSide: CGFloat = 100
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileSide), spacing: 8), count: 3)
    }

    /// 分类页签（磁贴形态的导航入口；显示器分类由 MonitorCommand/复合目录派生，不在扁平目录里）
    private struct CategoryTab: Identifiable {
        let key: String
        let title: String
        let symbol: String
        var id: String { key }
    }

    private let categoryTabs: [CategoryTab] = [
        .init(key: "custom", title: "自定义", symbol: "square.on.square"),
        .init(key: "monitor", title: "显示器", symbol: "display"),
        .init(key: "nav", title: "翻页 / 场景", symbol: "rectangle.split.2x2"),
        .init(key: "media", title: "媒体控制", symbol: "play.circle"),
        .init(key: "system", title: "系统", symbol: "gearshape"),
        .init(key: "template", title: "模板（待配置）", symbol: "square.and.pencil"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text("拖到键位使用；模板磁贴先点击配置")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // 停靠列:卡片撑满编辑器内容区高度,内容多时在卡片内部滚动
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        categoryTabGrid
                        selectedCategoryContent
                            .id(selectedCategory)  // 页签切换后滚回顶部,避免落在旧分类的滚动深度
                    }
                }
                .onChange(of: selectedCategory) { _, key in
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(key, anchor: .top) }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(width: 344, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // 浅色停靠卡片:与编辑器窗口同语言(旧浮层深色胶囊是悬浮 deco 的遗产,停靠后不再成立)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.black.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: 头部（标题行）

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintpalette")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("功能调色盘")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    // MARK: 分类页签（磁贴形态的导航入口）

    private var categoryTabGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(categoryTabs) { tab in
                categoryTile(tab)
            }
        }
    }

    private func categoryTile(_ tab: CategoryTab) -> some View {
        let isSelected = selectedCategory == tab.key
        return VStack(spacing: 7) {
            Image(systemName: tab.symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(tab.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 6)
        }
        .frame(width: tileSide, height: tileSide)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            withAnimation(.snappy(duration: 0.15)) { selectedCategory = tab.key }
        }
        .help(tab.key == "custom"
              ? "首页槽位镜像:拖到任意键位即整键复刻"
              : "查看\(tab.title)分类的磁贴")
    }

    /// 所选页签的内容：自定义 = 指定槽位实时镜像；显示器 = 复合 + 四组二级折叠；其余 = 扁平磁贴网格
    @ViewBuilder
    private var selectedCategoryContent: some View {
        if selectedCategory == "custom" {
            customCategoryContent
        } else if selectedCategory == "monitor" {
            monitorCategoryContent
        } else if let category = FunctionPaletteCatalog.flatCategories.first(where: { $0.key == selectedCategory }) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(category.items) { item in
                    tileView(item)
                }
            }
        }
    }

    // MARK: 自定义分类（首页槽位的配置镜像,与运行态解耦;拖拽 = 整键复刻）

    private var customCategoryContent: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(FunctionPaletteCatalog.customSlotIndices, id: \.self) { index in
                customSlotTile(index: index)
            }
        }
    }

    /// 槽位镜像磁贴:**固定镜像首页**(第一场景第一页)的槽位配置,与源键运行态解耦——
    /// 只渲染配置(标题/底色/动作语义图标)加动效静息帧(animationPreviewFrame,同模板磁贴机制),
    /// 不接 keyImageSlots 实时帧。零件语义:在任何场景/页打开,镜像都是同一份「我的常用键」;
    /// 源键的状态变化(睡眠锁 ON/OFF、插件推送图)不渗进调色盘;
    /// 拖拽载荷 "slot:<index>" → bindPayload 复刻首页该槽的**配置**。
    @ViewBuilder
    private func customSlotTile(index: Int) -> some View {
        let config = appModel.homeKeyConfig(at: index) ?? KeyConfig()
        let payload = "slot:\(index)"
        let isEmptySlot = AppModel.isEmptyMirrorKey(config)
        let tile = KeycapView(
            config: config,
            interactive: false,
            staticFrame: appModel.animationPreviewFrame(for: config)
        )
        .frame(width: tileSide, height: tileSide)
        .overlay(alignment: .topLeading) {
            // 源槽位号角标:识别这枚磁贴复刻自首页哪一格(1-based,与面板说法一致)
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(5)
        }
        .opacity(isEmptySlot ? 0.35 : 1) // 空槽镜像压暗:没有可复制的内容
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        if isEmptySlot {
            // 空槽禁拖:整键复刻一份空配置 = 把目标键静默清空(政策层 landingConfig 亦有闸门)
            tile.help("首页槽位 \(index + 1) 是空的,没有可复制的内容")
        } else {
            tile
                .draggable(payload) {
                    KeycapView(
                        config: config,
                        interactive: false,
                        staticFrame: appModel.animationPreviewFrame(for: config)
                    )
                    .frame(width: tileSide, height: tileSide)
                }
                .help("复制首页槽位 \(index + 1) 的磁贴,拖到目标键位(整键复刻,含底色)")
        }
    }

    // MARK: 显示器分类内容（复合 + 四组二级折叠，派生自 MonitorCommand / MonitorCompositeCatalog）

    private var monitorCategoryContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 「自定义/复合」小节已移除:输入切换动效键经「自定义」页签的槽位镜像复制更直接
            ForEach(MonitorGroup.allCases.filter { $0 != .composite }) { group in
                groupSection(group)
            }
        }
    }

    // MARK: 显示器分组（组 → 子分组）

    private func groupSection(_ group: MonitorGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(group.title, key: group.rawValue)
            if !collapsedSections.contains(group.rawValue) {
                ForEach(MonitorCommand.subgroups(in: group), id: \.self) { subgroup in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subgroup)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(MonitorCommand.allCases.filter {
                                $0.group == group && $0.subgroup == subgroup
                            }) { command in
                                tileView(FunctionPaletteItem(command: command))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 小节标题（仅显示器分类内部的子分组还在用折叠文本头）

    private func sectionHeader(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: collapsedSections.contains(key) ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.15)) {
                if collapsedSections.contains(key) {
                    collapsedSections.remove(key)
                } else {
                    collapsedSections.insert(key)
                }
            }
        }
        .help("折叠 / 展开")
    }

    // MARK: 磁贴 = 真实键帽渲染（复合磁贴显示动效帧；未配置模板磁贴带占位虚线）

    private func tileView(_ item: FunctionPaletteItem) -> some View {
        let config = tileConfig(for: item)
        let payload = effectivePayload(for: item)
        let base = KeycapView(
            config: config,
            interactive: false,
            staticFrame: appModel.animationPreviewFrame(for: config)
        )
        .frame(width: tileSide, height: tileSide)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 模板磁贴点击 = 配置参数(就绪后可再点改配置);即用磁贴无点击行为,拖拽是唯一放置手势
        .onTapGesture {
            if let kind = item.template {
                onConfigureTemplate(kind)
            }
        }
        .contextMenu {
            // 已配置草稿的模板磁贴:右键清除,不必重启或落键来复位
            if let kind = item.template, appModel.templateDrafts[kind] != nil {
                Button("清除已配置参数") {
                    appModel.setTemplateDraft(kind, nil)
                }
                .help("磁贴复原回占位态(已落键的不受影响)")
            }
        }
        .draggable(payload) {
            // 拖拽跟随图：与磁贴/最终键帽同源（复合带真实动效帧）
            KeycapView(
                config: config,
                interactive: false,
                staticFrame: appModel.animationPreviewFrame(for: config)
            )
            .frame(width: tileSide, height: tileSide)
        }
        .help(item.note ?? "")
        return base
    }

    /// 磁贴拖拽载荷:未配置模板走占位载荷 "template:<kind>"(落下 = 待配置键);
    /// 已配置就绪态走 "draft:<kind>"(bindPayload 取整份配置落键并消费草稿,磁贴复原)
    private func effectivePayload(for item: FunctionPaletteItem) -> String {
        if let kind = item.template, appModel.templateDrafts[kind] != nil {
            return "draft:\(kind.rawValue)"
        }
        return item.payload
    }

    /// 磁贴 → 键帽配置（与落下后的最终键面一致）。
    /// 就绪模板显示配置后的键面(标题/动作,无占位虚线);未配置模板带占位虚线;
    /// 底色取 KeyConfig 默认色——落到空槽位即此色(落到已有色槽位则保留原色,见 bindPayload)。
    private func tileConfig(for item: FunctionPaletteItem) -> KeyConfig {
        if let kind = item.template, let draft = appModel.templateDrafts[kind] {
            return KeyConfig(
                title: draft.title, backgroundColorHex: "#3B4252",
                iconPath: draft.iconPath, action: draft.action,
                animation: draft.animation, template: nil
            )
        }
        return KeyConfig(
            title: item.title, backgroundColorHex: "#3B4252",
            iconPath: nil, action: item.action,
            animation: item.animation, template: item.template
        )
    }
}
