import CoreGraphics

/// OpenDeck 侧唯一的 hex → 色值解析(parse 供 IconRenderer 管线,components 供 UI 侧)。
///
/// 收敛前 App 里有三份实现,其中 `StatTileRenderer.color` 还被热力图渲染器反向借用
/// (KeyboardHeatmapRenderer / KeyboardHeatmapAnimator 直接调 StatTileRenderer.color),
/// 等于「热力图依赖 stats 文件」——两个子系统本无关系。KeyPalette(键帽 UI 色)
/// 也曾自带一份解析,2026-11-01 起委托这里的 components(漂移实证:7 位输入
/// 曾被 KeyPalette 产出错位色,而这里正确返回 nil)。
///
/// 为什么不用 StreamDockKit 里那份 `HexColor`:MonitorInputIcon.swift 必须能单文件编译
/// (`swiftc MonitorInputIcon.swift Scripts/RenderMonitorIconFrames.swift`,预览工具不引入
/// 整个包),`import StreamDockKit` 会直接打死这条路径。所以这里只依赖 CoreGraphics,
/// 预览工具把它和渲染器一起编译即可;kit 内部那份仍归 kit 自用(跨 target 无法共享)。
enum HexCGColor {
    /// 解析为 sRGB 分量(r/g/b/a 均 0...1);非法输入返回 nil,不静默产出黑色。
    /// 唯一解析实现——规则调整(如短写支持)只改这一处。
    static func components(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let raw = UInt64(value, radix: 16) else { return nil }
        let r, g, b, a: UInt64
        if value.count == 8 {
            (r, g, b, a) = ((raw >> 24) & 0xFF, (raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
        } else {
            (r, g, b, a) = ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF, 0xFF)
        }
        return (r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: Double(a) / 255)
    }

    /// 解析为 CGColor(sRGB)。
    static func parse(_ hex: String) -> CGColor? {
        guard let c = components(hex) else { return nil }
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// 解析为不透明色(忽略 hex 里的 alpha)。键面配色一律不透明确色,便于叠加。
    static func opaque(_ hex: String) -> CGColor? {
        parse(hex).flatMap { $0.copy(alpha: 1) }
    }
}
