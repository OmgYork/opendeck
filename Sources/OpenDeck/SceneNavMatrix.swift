import SwiftUI

// MARK: - 矩阵导航(方案 A 下置 / 方案 B 右缘转置)
//
// 「场景芯片栏 + 页点胶囊」合并为一张 (场景 × 页) 全景地图:任一格点按即跨场景直达
// 该 (场景, 页),无需两步扫动。方向语义与两轴手势同构(经典:A 横轴=场景纵轴=页;
// B 为右缘竖长卡片转置:纵轴=场景、横轴=页)。手势逻辑只依赖 AppModel 状态,三种样式行为一致。

extension EditorView {
    /// 方案 A:矩阵·下置——每场景一列(芯片=列头,页点纵排在下),尾部「+ 添加场景」
    var matrixBelowNav: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(appModel.config.config.scenes.enumerated()), id: \.element.id) { offset, scene in
                VStack(spacing: 7) {
                    sceneChip(offset: offset, scene: scene)
                    VStack(spacing: 8) {
                        ForEach(0..<scene.pages.count, id: \.self) { position in
                            matrixDot(
                                isCurrent: offset == appModel.config.config.currentSceneIndex
                                    && position == appModel.config.config.currentPageIndex,
                                onDark: false
                            )
                            .onTapGesture { jumpToScene(offset, page: position) }
                        }
                    }
                }
            }
            addSceneChip
        }
        .padding(.horizontal, 4)
        .animation(.snappy(duration: 0.25), value: appModel.config.config.currentSceneIndex)
        .animation(.snappy(duration: 0.25), value: appModel.config.config.currentPageIndex)
    }

    /// 方案 B:矩阵·右缘(转置)——底座旁挂深色轨:每场景一行(芯片=行头,页点横排),底部「+」;
    /// 行头芯片点按 = 切场景(回该场景第一页),行内页点点按 = 直达该 (场景, 页)。
    /// 行 leading 对齐:芯片列即「场景纵轴」,长短不一的页点行向右延伸,不做逐行居中
    var railMatrixNav: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(appModel.config.config.scenes.enumerated()), id: \.element.id) { offset, scene in
                HStack(spacing: 7) {
                    sceneChip(offset: offset, scene: scene)
                    HStack(spacing: 7) {
                        ForEach(0..<scene.pages.count, id: \.self) { position in
                            matrixDot(
                                isCurrent: offset == appModel.config.config.currentSceneIndex
                                    && position == appModel.config.config.currentPageIndex,
                                onDark: true
                            )
                            .onTapGesture { jumpToScene(offset, page: position) }
                        }
                    }
                }
            }
            addSceneChip
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .center)
        // 与键盘底座同族的深色轨:芯片/白点在深底上与经典页点胶囊同一套视觉语言
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.38), .black.opacity(0.22)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.30), radius: 16, y: 6)
        .animation(.snappy(duration: 0.25), value: appModel.config.config.currentSceneIndex)
        .animation(.snappy(duration: 0.25), value: appModel.config.config.currentPageIndex)
    }

    /// 矩阵圆点:onDark(右缘深色轨)用白点,与经典页点胶囊同语言;
    /// 窗底(下置矩阵)用 primary 点,与芯片同语言、亮/暗外观自适应
    private func matrixDot(isCurrent: Bool, onDark: Bool) -> some View {
        Group {
            if onDark {
                Circle()
                    .fill(isCurrent ? Color.white : Color.white.opacity(0.32))
            } else {
                Circle()
                    .fill(isCurrent ? Color.primary.opacity(0.85) : Color.primary.opacity(0.22))
            }
        }
        .frame(width: isCurrent ? 8 : 6, height: isCurrent ? 8 : 6)
        .contentShape(Circle())
    }

    /// 矩阵点按直达:跨场景定位 (场景, 页)。
    /// switchPage(to:) 先切场景(回该场景第一页)再显式落页,落点即点按格
    private func jumpToScene(_ sceneIndex: Int, page: Int) {
        guard let id = appModel.config.pageIDInScene(sceneIndex, position: page) else { return }
        appModel.switchPage(to: id)
    }
}
