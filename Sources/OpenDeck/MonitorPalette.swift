import SwiftUI

// MARK: - 显示器功能托盘（独立浮动 deco）
//
// 从「矩阵·右缘」挂轨的深色胶囊语言里剥出来的独立面板：可拖动、可收起。
// 2026-10-23 v3：磁贴 = **真实键帽渲染**（KeycapView，100pt 与编辑器槽位 1:1；
// 复合磁贴直接显示动效帧，拖拽跟随图同源）；置顶「自定义/复合」；分组可折叠；
// 指针悬停时滚动只作用于托盘（由 EditorView 的 onHover 门控 SwipePageMonitor）。
// 载荷（拖拽/点选统一）：MonitorCommand.rawValue 或 "composite:<id>"。

struct MonitorPaletteView: View {
    let appModel: AppModel
    /// 当前点选的载荷（点选绑定模式下高亮）
    var picked: String? = nil
    /// 点选回调：点条目 → 再点键位即绑定
    var onPick: (String) -> Void = { _ in }

    @State private var collapsed = false
    @State private var offset: CGSize = .zero
    @State private var dragAnchor: CGSize = .zero
    /// 折叠的分组 key（默认：四个功能组全折叠，自定义/复合展开）
    @State private var collapsedSections: Set<String> = ["picture", "game", "audio", "input"]

    private let tileSide: CGFloat = 100
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileSide), spacing: 8), count: 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: collapsed ? 0 : 12) {
            header
            if !collapsed {
                Text(pickedHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        compositeSection
                        ForEach(MonitorGroup.allCases.filter { $0 != .composite }) { group in
                            groupSection(group)
                        }
                    }
                }
                .frame(maxHeight: 560)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(width: collapsed ? nil : 344, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.72), .black.opacity(0.58)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .offset(offset)
    }

    // MARK: 头部（拖动把手 + 收起）

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("显示器")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(collapsed ? "展开" : "收起")
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: dragAnchor.width + value.translation.width,
                        height: dragAnchor.height + value.translation.height
                    )
                }
                .onEnded { _ in dragAnchor = offset }
        )
        .help("拖动移动托盘")
    }

    private var pickedHint: String {
        guard let picked else { return "拖到键位，或点一下再点键位" }
        if let tile = MonitorCompositeCatalog.tile(payload: picked) {
            return "已选中「\(tile.title)」，再点一个键位"
        }
        if let command = MonitorCommand(rawValue: picked) {
            return "已选中「\(command.title)」，再点一个键位"
        }
        return "已选中，再点一个键位"
    }

    // MARK: 置顶：自定义 / 复合

    private var compositeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("自定义 / 复合", key: "composite")
            if !collapsedSections.contains("composite") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(MonitorCompositeCatalog.all) { tile in
                        tileView(payload: tile.payload, note: tile.note)
                    }
                }
            }
        }
    }

    // MARK: 分组（组 → 小节）

    private func groupSection(_ group: MonitorGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(group.title, key: group.rawValue)
            if !collapsedSections.contains(group.rawValue) {
                ForEach(MonitorCommand.subgroups(in: group), id: \.self) { subgroup in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subgroup)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(MonitorCommand.allCases.filter {
                                $0.group == group && $0.subgroup == subgroup
                            }) { command in
                                tileView(payload: command.rawValue, note: command.spec.note)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: collapsedSections.contains(key) ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
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

    // MARK: 磁贴 = 真实键帽渲染（复合磁贴显示动效帧）

    private func tileView(payload: String, note: String?) -> some View {
        let config = tileConfig(for: payload)
        let isPicked = picked == payload
        return KeycapView(
            config: config ?? KeyConfig(),
            interactive: false,
            staticFrame: config.flatMap { appModel.animationPreviewFrame(for: $0) }
        )
        .frame(width: tileSide, height: tileSide)
        .overlay {
            if isPicked {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onPick(payload) }
        .draggable(payload) {
            // 拖拽跟随图：与磁贴/最终键帽同源（复合带真实动效帧）
            KeycapView(
                config: config ?? KeyConfig(),
                interactive: false,
                staticFrame: config.flatMap { appModel.animationPreviewFrame(for: $0) }
            )
            .frame(width: tileSide, height: tileSide)
        }
        .help(note ?? "")
    }

    /// 载荷 → 键帽配置（与落下后的最终键面一致）
    private func tileConfig(for payload: String) -> KeyConfig? {
        if let tile = MonitorCompositeCatalog.tile(payload: payload) {
            return KeyConfig(title: tile.title, backgroundColorHex: "#000000",
                             iconPath: nil, action: tile.action, animation: tile.animation)
        }
        if let command = MonitorCommand(rawValue: payload) {
            return KeyConfig(title: command.title, backgroundColorHex: "#000000",
                             iconPath: nil, action: .monitor(command), animation: nil)
        }
        return nil
    }
}
