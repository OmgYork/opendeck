import AppKit
import StreamDockKit
import SwiftUI

// MARK: - 键帽(拟真键面)

/// 一颗键的视觉呈现:底色渐变 + 顶部光泽 + 底图 + 标题 + 动作角标。
/// 网格单元与编辑器实时预览共用,保证「编辑器里看到的 = 设备上亮起的」。
/// 交互遵循 fluid interfaces:悬停浮起、按下凹陷,弹簧可中断。
struct KeycapView: View {
    let config: KeyConfig
    /// 预览场景禁用悬停动效
    var interactive = true
    /// 物理设备上正被按住(远程按压态:凹陷 + 发光描边)
    var remotePressed = false

    @State private var hovering = false

    private var palette: KeyPalette { KeyPalette(hex: config.backgroundColorHex) }
    private var isEmptyKey: Bool {
        config.title.isEmpty && config.iconPath == nil && config.action == nil
    }

    var body: some View {
        // 布局锚:基础形状链(overlays 不参与布局, oversized 图片不会撑爆网格)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [palette.color.lighten(by: 0.10), palette.color],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay {
                // 顶部光泽:让键面读作有厚度的实体,而非平面色块
                LinearGradient(
                    colors: [.white.opacity(0.22), .white.opacity(0.02)],
                    startPoint: .top, endPoint: .center
                )
            }
            .overlay {
                if let path = config.iconPath, let image = NSImage(contentsOfFile: path) {
                    // scaledToFill 溢出部分由整体 clipShape 裁掉
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if config.iconPath != nil {
                    // 压暗底图,保证标题可读(vibrancy 原则:重背景配重文字)
                    Rectangle().fill(.black.opacity(0.18))
                }
            }
            .overlay {
                if isEmptyKey {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .overlay(alignment: .bottom) {
                if !config.title.isEmpty {
                    Text(config.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 7)
                        .padding(.bottom, 7)
                        .shadow(color: .black.opacity(palette.isLight ? 0 : 0.55), radius: 2, y: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let action = config.action {
                    Image(systemName: ActionStyle.symbol(for: action))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(palette.textColor.opacity(0.85))
                        .padding(5)
                        .background(.black.opacity(0.22), in: Circle())
                        .padding(6)
                }
            }
            .overlay {
                // 键帽边缘:一圈极细高光,深浅两种模式都成立
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .overlay {
                if remotePressed {
                    // 物理按压的即时可视反馈:发光描边
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.65), lineWidth: 2.5)
                        .shadow(color: .white.opacity(0.35), radius: 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(scale, anchor: .center)
            .shadow(
                color: .black.opacity(lifted ? 0.28 : 0.16),
                radius: lifted ? 10 : 4,
                y: lifted ? 5 : 2
            )
            .animation(.snappy(duration: 0.22), value: hovering && interactive)
            .animation(.snappy(duration: 0.12), value: remotePressed)
            .onHover { hovering = $0 }
    }

    /// 视觉层级:远程按压(凹陷)< 悬停(浮起)< 默认
    private var lifted: Bool { hovering && interactive && !remotePressed }
    private var scale: CGFloat {
        if remotePressed { return 0.94 }
        return lifted ? 1.045 : 1
    }
}

/// 网格单元按钮:按压瞬间即凹陷(fluid interfaces §1——反馈发生在按下,而非抬起)
struct KeycapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - 颜色小工具

extension Color {
    /// 键帽顶部提亮;简单 RGB 插值够用,不引 ColorMath
    func lighten(by amount: Double) -> Color {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let blended = srgb.blended(withFraction: amount, of: .white) ?? srgb
        return Color(nsColor: blended)
    }
}

// MARK: - 动作角标

/// 动作 → SF Symbol(网格角标与编辑器共用)
enum ActionStyle {
    static func symbol(for action: KeyAction) -> String {
        switch action {
        case .openApp: "app"
        case .openURL: "link"
        case .runShortcut: "wand.and.stars"
        case .shellScript: "terminal"
        case .appleScript: "chevron.left.forwardslash.chevron.right"
        case .hotkey: "keyboard"
        case .mediaKey: "play.circle"
        case .plugin: "puzzlepiece.extension"
        }
    }

    static func label(for action: KeyAction) -> String {
        switch action {
        case .openApp: "打开应用"
        case .openURL: "打开网址"
        case .runShortcut: "快捷指令"
        case .shellScript: "Shell"
        case .appleScript: "AppleScript"
        case .hotkey: "热键"
        case .mediaKey: "媒体"
        case .plugin: "插件"
        }
    }
}
