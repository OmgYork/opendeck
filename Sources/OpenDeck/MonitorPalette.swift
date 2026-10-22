import SwiftUI

// MARK: - 显示器功能托盘（独立浮动 deco）
//
// 从「矩阵·右缘」挂轨的深色胶囊语言里剥出来的独立面板：可拖动、可收起、
// 条目可拖到 15 个真实键位上（落下即绑定 .monitor 动作）。
// 视觉与底座/挂轨同族：黑 0.38→0.22 渐变 + 1pt 白 7% 描边 + 圆角 20。

struct MonitorPaletteView: View {
    /// 当前点选的命令(点选绑定模式下高亮)
    var picked: MonitorCommand? = nil
    /// 点选回调:点条目 → 再点键位即绑定
    var onPick: (MonitorCommand) -> Void = { _ in }

    @State private var collapsed = false
    @State private var offset: CGSize = .zero
    @State private var dragAnchor: CGSize = .zero

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: collapsed ? 0 : 12) {
            header
            if !collapsed {
                Text(picked == nil ? "拖到键位，或点一下再点键位" : "已选中「\(picked?.title ?? "")」，再点一个键位")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                ForEach(MonitorGroup.allCases) { group in
                    groupSection(group)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(width: collapsed ? nil : 288, alignment: .leading)
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

    // MARK: 分组

    private func groupSection(_ group: MonitorGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(MonitorCommand.allCases.filter { $0.group == group && !$0.spec.unavailable }) { command in
                    paletteItem(command)
                }
            }
        }
    }

    private func paletteItem(_ command: MonitorCommand) -> some View {
        VStack(spacing: 4) {
            Image(systemName: command.symbol)
                .font(.system(size: 15, weight: .medium))
            Text(command.title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white.opacity(0.92))
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(picked == command ? 0.22 : 0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            picked == command ? .white.opacity(0.85) : .white.opacity(0.08),
                            lineWidth: picked == command ? 2 : 1
                        )
                }
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { onPick(command) }
        .draggable(command.rawValue) {
            // 拖拽跟随图：与条目同视觉，避免系统默认灰块
            VStack(spacing: 3) {
                Image(systemName: command.symbol).font(.system(size: 14))
                Text(command.title).font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        }
        .help(command.spec.note ?? command.title)
    }
}
