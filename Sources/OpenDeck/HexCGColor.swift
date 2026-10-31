import CoreGraphics

/// OpenDeck 侧唯一的 hex → CGColor 解析。
///
/// 收敛前 App 里有三份实现,其中 `StatTileRenderer.color` 还被热力图渲染器反向借用
/// (KeyboardHeatmapRenderer / KeyboardHeatmapAnimator 直接调 StatTileRenderer.color),
/// 等于「热力图依赖 stats 文件」——两个子系统本无关系。
///
/// 为什么不用 StreamDockKit 里那份 `HexColor`:MonitorInputIcon.swift 必须能单文件编译
/// (`swiftc MonitorInputIcon.swift Scripts/RenderMonitorIconFrames.swift`,预览工具不引入
/// 整个包),`import StreamDockKit` 会直接打死这条路径。所以这里只依赖 CoreGraphics,
/// 预览工具把它和渲染器一起编译即可;kit 内部那份仍归 kit 自用(跨 target 无法共享)。
enum HexCGColor {
    /// 解析 "#RRGGBB" / "RRGGBB" / "#RRGGBBAA" / "RRGGBBAA"。
    /// 非法输入返回 nil(调用方各自决定兜底色),不静默产出黑色。
    static func parse(_ hex: String) -> CGColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let raw = UInt64(value, radix: 16) else { return nil }
        let r, g, b, a: UInt64
        if value.count == 8 {
            (r, g, b, a) = ((raw >> 24) & 0xFF, (raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
        } else {
            (r, g, b, a) = ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF, 0xFF)
        }
        return CGColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }

    /// 解析为不透明色(忽略 hex 里的 alpha)。键面配色一律不透明确色,便于叠加。
    static func opaque(_ hex: String) -> CGColor? {
        guard let color = parse(hex).flatMap({ $0.copy(alpha: 1) }) else { return nil }
        return color
    }
}
