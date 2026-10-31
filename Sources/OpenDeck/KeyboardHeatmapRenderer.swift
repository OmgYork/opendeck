import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - 键面渲染（112×112）
//
// 设计坐标是 y 向下（与设计稿一致），内部换算成 CoreGraphics 的 y 向上；
// 输出前预旋转 180°（设备倒装），UI 镜像侧 KeycapView 会转回正立。
//
// 两个元件：① 状态轨（顶部灯带，8px）② 主内容（数值 / 文字提示）。
// 底色在全部状态叠加 6% 暖黄底噪。

enum HeatmapLamp {
    case white, red, green, gray

    var color: CGColor? {
        switch self {
        case .white: StatTileRenderer.color("#FFFFFF")
        case .red: StatTileRenderer.color("#FF4D4F")
        case .green: StatTileRenderer.color("#34C759")
        case .gray: StatTileRenderer.color("#8E8A87")
        }
    }
}

struct HeatmapScene {
    var numberFrom: String
    var numberTo: String
    var roll: CGFloat = 0
    var alpha: CGFloat = 1
    /// 中断/重试/未运行时用文字替换主数值；nil = 显示数字
    var prompt: String? = nil
    var promptAlpha: CGFloat = 0
    /// 主提示的字号与颜色（默认 28px 暖黄；未运行态用 34px 灰 X）
    var promptSize: CGFloat = 28
    var promptColor: CGColor? = nil
    /// 整键暖黄底噪（全状态常驻 6%）
    var wash: CGFloat = 1
    /// 顶部灯带
    var lamp: HeatmapLamp = .white
    var lampIntensity: CGFloat = 0.92
    var flash: CGFloat = 0
    var shake: CGFloat = 0
    var sheen: CGFloat = 0
    var dim: CGFloat = 0
}

enum HeatmapGeometry {
    static let side: CGFloat = 112
    static let lampX: CGFloat = 24
    static let lampW: CGFloat = 64
    static let lampCenterY: CGFloat = 20
    static let lampH: CGFloat = 8
    static let contentCenterY: CGFloat = 58
}

enum HeatmapPalette {
    static let background = "#1B1918"
    static let ink = "#FFFFFF"
    static let pink = "#F7A6AC"
    static let warn = "#F5BA4C"
    static let gray = "#8E8A87"
}

enum HeatmapRenderer {
    static func image(scene: HeatmapScene, side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let k = CGFloat(side) / HeatmapGeometry.side
        ctx.scaleBy(x: k, y: k)
        draw(scene: scene, in: ctx, side: HeatmapGeometry.side)

        guard let upright = ctx.makeImage() else { return nil }
        return rotated180(upright, side: side, space: space)
    }

    private static func draw(scene: HeatmapScene, in ctx: CGContext, side S: CGFloat) {
        func flip(_ y: CGFloat) -> CGFloat { S - y }
        func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x, y: S - top - h, width: w, height: h)
        }

        ctx.saveGState()
        if scene.shake != 0 { ctx.translateBy(x: scene.shake, y: 0) }

        if let background = StatTileRenderer.color(HeatmapPalette.background) {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        }
        if let warm = StatTileRenderer.color(HeatmapPalette.warn) {
            let colors = [warm.copy(alpha: 0.10) ?? warm, warm.copy(alpha: 0) ?? warm] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(g,
                                       startCenter: CGPoint(x: 20, y: flip(8)), startRadius: 2,
                                       endCenter: CGPoint(x: 20, y: flip(8)), endRadius: 72,
                                       options: [])
            }
            // 全状态 6% 暖黄底噪
            ctx.setFillColor(warm.copy(alpha: 0.06 * scene.wash) ?? warm)
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        }
        if let white = StatTileRenderer.color("#FFFFFF") {
            let colors = [white.copy(alpha: 0.055) ?? white, white.copy(alpha: 0) ?? white] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: rect(0, 0, S, 42))
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: flip(0)),
                                       end: CGPoint(x: 0, y: flip(42)), options: [])
                ctx.restoreGState()
            }
        }

        drawLamp(ctx: ctx, scene: scene, flip: flip)
        drawNumber(ctx: ctx, scene: scene, side: S, flip: flip, rect: rect)
        if let prompt = scene.prompt, scene.promptAlpha > 0 {
            drawPrompt(ctx: ctx, text: prompt, alpha: scene.promptAlpha,
                       size: scene.promptSize, color: scene.promptColor, flip: flip)
        }

        if scene.flash > 0, let pink = StatTileRenderer.color(HeatmapPalette.pink) {
            ctx.setFillColor(pink.copy(alpha: 0.12 * scene.flash) ?? pink)
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        }
        if scene.sheen > 0, let white = StatTileRenderer.color("#FFFFFF") {
            let colors = [white.copy(alpha: 0.08 * scene.sheen) ?? white, white.copy(alpha: 0) ?? white] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: rect(0, 0, S, 56))
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: flip(0)),
                                       end: CGPoint(x: 0, y: flip(56)), options: [])
                ctx.restoreGState()
            }
        }
        if scene.dim > 0, let black = StatTileRenderer.color("#000000") {
            ctx.setFillColor(black.copy(alpha: 0.06 * scene.dim) ?? black)
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        }
        ctx.restoreGState()
    }

    /// 顶部灯带：圆角条 + 同色外发光 + 上沿高光，做出「发光体」的厚度。
    private static func drawLamp(ctx: CGContext, scene: HeatmapScene, flip: (CGFloat) -> CGFloat) {
        guard scene.lampIntensity > 0.01, let color = scene.lamp.color else { return }
        let lampH = HeatmapGeometry.lampH
        let r = CGRect(x: HeatmapGeometry.lampX,
                       y: flip(HeatmapGeometry.lampCenterY + lampH / 2),
                       width: HeatmapGeometry.lampW, height: lampH)
        let path = CGPath(roundedRect: r, cornerWidth: lampH / 2,
                          cornerHeight: lampH / 2, transform: nil)

        ctx.saveGState()
        ctx.setAlpha(scene.lampIntensity)
        ctx.setShadow(offset: .zero, blur: 7, color: color)
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        if let white = StatTileRenderer.color("#FFFFFF"),
           let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [white.copy(alpha: 0.35) ?? white,
                                              white.copy(alpha: 0) ?? white] as CFArray,
                                     locations: [0, 0.45]) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: r.maxY),
                                   end: CGPoint(x: 0, y: r.minY), options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private static func drawPrompt(ctx: CGContext, text: String, alpha: CGFloat,
                                   size: CGFloat, color: CGColor?, flip: (CGFloat) -> CGFloat) {
        let font = CTFontCreateWithName(NSFont.systemFont(ofSize: size, weight: .semibold).fontName as CFString,
                                        size, nil)
        guard let ink = color ?? StatTileRenderer.color(HeatmapPalette.warn) else { return }
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: ink) ?? NSColor.systemYellow,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        // 与主数值共用同一条光学中线（数字基线 70、34px 字身高 24.4 → 中线 57.8）
        ctx.textPosition = CGPoint(x: 56 - width / 2,
                                   y: flip(HeatmapGeometry.contentCenterY) - bounds.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawNumber(ctx: CGContext, scene: HeatmapScene, side S: CGFloat,
                                   flip: (CGFloat) -> CGFloat,
                                   rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect) {
        let to = scene.numberTo
        let from = scene.numberFrom
        let size: CGFloat = to.count >= 5 ? 26 : 34
        let baseTop: CGFloat = 70
        let baseY = flip(baseTop)

        let font = CTFontCreateWithName(NSFont.systemFont(ofSize: size, weight: .semibold).fontName as CFString,
                                        size, nil)
        func width(of text: String) -> CGFloat {
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
        }
        let cell = "0123456789".map { width(of: String($0)) }.max() ?? size * 0.6
        let totalW = cell * CGFloat(to.count)
        let startX = 56 - totalW / 2 + cell / 2
        let rollDist = size * 0.42

        ctx.saveGState()
        ctx.setAlpha(scene.alpha)

        func draw(_ text: String, atX cx: CGFloat, y: CGFloat, alpha: CGFloat) {
            let attr = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.white,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.textPosition = CGPoint(x: cx - w / 2, y: y)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        let rollable = scene.roll > 0 && from.count == to.count
        if scene.roll > 0, !rollable {
            draw(from, atX: 56, y: baseY, alpha: scene.alpha * (1 - scene.roll))
            draw(to, atX: 56, y: baseY, alpha: scene.alpha * scene.roll)
            ctx.restoreGState()
            return
        }

        let toChars = Array(to)
        let fromChars = Array(from)
        for i in 0..<toChars.count {
            let cx = startX + CGFloat(i) * cell
            let newChar = String(toChars[i])
            let oldChar = i < fromChars.count ? String(fromChars[i]) : ""
            if !rollable || oldChar == newChar {
                draw(newChar, atX: cx, y: baseY, alpha: scene.alpha)
            } else {
                ctx.saveGState()
                ctx.clip(to: rect(cx - cell / 2, baseTop - size * 0.95, cell, size * 1.25))
                draw(oldChar, atX: cx, y: baseY + rollDist * scene.roll, alpha: scene.alpha)
                draw(newChar, atX: cx, y: baseY - rollDist * (1 - scene.roll), alpha: scene.alpha)
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }

    private static func rotated180(_ image: CGImage, side: Int, space: CGColorSpace) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: CGFloat(side), y: CGFloat(side))
        ctx.rotate(by: .pi)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        return ctx.makeImage()
    }
}
