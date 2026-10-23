import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - 键面渲染（112×112）
//
// 设计坐标是 y 向下（与设计稿一致），内部换算成 CoreGraphics 的 y 向上；
// 输出前预旋转 180°（设备倒装），UI 镜像侧 KeycapView 会转回正立。
//
// 版式只有三样东西：主数字、状态轨、键盘徽标。键面上没有第二个字。

enum HeatmapRailKind { case idle, warn, retry, off }

struct HeatmapScene {
    var numberFrom: String
    var numberTo: String
    var roll: CGFloat = 0
    var alpha: CGFloat = 1
    var rail: HeatmapRailKind = .idle
    var railHeight: CGFloat = 2
    var hatch: CGFloat = 1
    var hatchShift: CGFloat = 0
    var dotBrightness: CGFloat = 0.55
    var flash: CGFloat = 0
    var shake: CGFloat = 0
    var sheen: CGFloat = 0
    var dim: CGFloat = 0
    var badgeAlpha: CGFloat = 0.45
    var warnBadge: Bool = false
    var sweep: CGFloat = 0
}

enum HeatmapPalette {
    static let background = "#1B1918"
    static let ink = "#FFFFFF"
    static let pink = "#F7A6AC"
    static let warn = "#F5BA4C"
}

enum HeatmapRenderer {
    static let inkDimAlpha: CGFloat = 0.45
    static let inkFaintAlpha: CGFloat = 0.25

    static func image(scene: HeatmapScene, side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let s = CGFloat(side)
        let k = s / 112   // 设计稿 → 实际尺寸
        ctx.scaleBy(x: k, y: k)
        draw(scene: scene, in: ctx, side: k == 1 ? 112 : 112)

        guard let upright = ctx.makeImage() else { return nil }
        return rotated180(upright, side: side, space: space)
    }

    // MARK: 主绘制（设计坐标 112×112，y 向下）

    private static func draw(scene: HeatmapScene, in ctx: CGContext, side: CGFloat) {
        let S = side
        func flip(_ y: CGFloat) -> CGFloat { S - y }
        func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x, y: S - top - h, width: w, height: h)
        }

        ctx.saveGState()
        if scene.shake != 0 { ctx.translateBy(x: scene.shake, y: 0) }

        // 底
        if let background = color(HeatmapPalette.background) {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        }

        // 左上暖光
        if let warm = color("#F5BA4C") {
            let colors = [warm.copy(alpha: 0.10) ?? warm, warm.copy(alpha: 0) ?? warm] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(gradient,
                                       startCenter: CGPoint(x: 20, y: flip(8)), startRadius: 2,
                                       endCenter: CGPoint(x: 20, y: flip(8)), endRadius: 72,
                                       options: [])
            }
        }

        // 顶部玻璃高光
        if let white = color("#FFFFFF") {
            let colors = [white.copy(alpha: 0.055) ?? white, white.copy(alpha: 0) ?? white] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: rect(0, 0, S, 42))
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: flip(0)),
                                       end: CGPoint(x: 0, y: flip(42)),
                                       options: [])
                ctx.restoreGState()
            }
        }

        drawBadge(ctx: ctx, flip: flip, alpha: scene.badgeAlpha, warn: scene.warnBadge)
        drawNumber(ctx: ctx, scene: scene, side: S, flip: flip, rect: rect)
        drawRail(ctx: ctx, scene: scene, side: S, flip: flip, rect: rect)

        // 增长粉洗
        if scene.flash > 0, let pink = color(HeatmapPalette.pink) {
            ctx.setFillColor(pink.copy(alpha: 0.12 * scene.flash) ?? pink)
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        }
        // 按下扫光
        if scene.sheen > 0, let white = color("#FFFFFF") {
            let colors = [white.copy(alpha: 0.08 * scene.sheen) ?? white, white.copy(alpha: 0) ?? white] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: rect(0, 0, S, 56))
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: flip(0)),
                                       end: CGPoint(x: 0, y: flip(56)),
                                       options: [])
                ctx.restoreGState()
            }
        }
        // 按下压暗
        if scene.dim > 0, let black = color("#000000") {
            ctx.setFillColor(black.copy(alpha: 0.06 * scene.dim) ?? black)
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        }

        ctx.restoreGState()
    }

    // MARK: 徽标

    private static func drawBadge(ctx: CGContext, flip: (CGFloat) -> CGFloat,
                                  alpha: CGFloat, warn: Bool) {
        guard let stroke = color(warn ? HeatmapPalette.warn : HeatmapPalette.warn) else { return }
        let x: CGFloat = 12, top: CGFloat = 12, w: CGFloat = 13, h: CGFloat = 10, r: CGFloat = 2.2
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(1.1)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x + r, y: flip(top)))
        p.addLine(to: CGPoint(x: x + w - r, y: flip(top)))
        p.addQuadCurve(to: CGPoint(x: x + w, y: flip(top + r)),
                       control: CGPoint(x: x + w, y: flip(top)))
        p.addLine(to: CGPoint(x: x + w, y: flip(top + h - r)))
        p.addQuadCurve(to: CGPoint(x: x + w - r, y: flip(top + h)),
                       control: CGPoint(x: x + w, y: flip(top + h)))
        p.addLine(to: CGPoint(x: x + r, y: flip(top + h)))
        p.addQuadCurve(to: CGPoint(x: x, y: flip(top + h - r)),
                       control: CGPoint(x: x, y: flip(top + h)))
        p.addLine(to: CGPoint(x: x, y: flip(top + r)))
        p.addQuadCurve(to: CGPoint(x: x + r, y: flip(top)),
                       control: CGPoint(x: x, y: flip(top)))
        ctx.addPath(p)
        ctx.strokePath()

        ctx.setAlpha(alpha * 0.85)
        ctx.setLineWidth(0.9)
        let cw: CGFloat = 2.4, gap: CGFloat = 1.4
        let total = 3 * cw + 2 * gap
        for i in 0..<3 {
            let sx = x + (w - total) / 2 + CGFloat(i) * (cw + gap)
            ctx.stroke(CGRect(x: sx, y: flip(top + 2.6 + 2.0), width: cw, height: 2.0))
            ctx.stroke(CGRect(x: sx, y: flip(top + 5.8 + 2.0), width: cw, height: 2.0))
        }
        ctx.restoreGState()
    }

    // MARK: 数字

    private static func drawNumber(ctx: CGContext, scene: HeatmapScene, side S: CGFloat,
                                   flip: (CGFloat) -> CGFloat,
                                   rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect) {
        let to = scene.numberTo
        let from = scene.numberFrom
        let size: CGFloat = to.count >= 5 ? 26 : 34
        let baseTop: CGFloat = 70          // 设计稿基线
        let baseY = flip(baseTop)

        let font = CTFontCreateWithName(NSFont.systemFont(ofSize: size, weight: .semibold).fontName as CFString,
                                        size, nil)
        func width(of text: String) -> CGFloat {
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attr)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let cell = "0123456789".map { width(of: String($0)) }.max() ?? size * 0.6
        let totalW = cell * CGFloat(to.count)
        let startX = 56 - totalW / 2 + cell / 2
        let rollDist = size * 0.42

        ctx.saveGState()
        ctx.setAlpha(scene.alpha)
        if let ink = color(HeatmapPalette.ink) { ctx.setFillColor(ink) }

        func draw(_ text: String, atX cx: CGFloat, y: CGFloat, alpha: CGFloat) {
            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
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
            // 长度/单位变了（9999 → 10.0k、8432 → 0）：滚动会读成乱码，改交叉淡换
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

    // MARK: 状态轨

    private static func drawRail(ctx: CGContext, scene: HeatmapScene, side S: CGFloat,
                                 flip: (CGFloat) -> CGFloat,
                                 rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect) {
        let x: CGFloat = 24, w: CGFloat = 64, centerTop: CGFloat = 92
        let h = scene.railHeight
        let top = centerTop - h / 2

        func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
            CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        switch scene.rail {
        case .idle:
            if let pink = color(HeatmapPalette.pink) {
                ctx.setFillColor(pink.copy(alpha: 0.30) ?? pink)
                ctx.addPath(roundedPath(rect(x, top, w, h), h / 2))
                ctx.fillPath()
                ctx.setFillColor(pink.copy(alpha: 0.30 + 0.55 * scene.dotBrightness) ?? pink)
                ctx.fillEllipse(in: CGRect(x: x + w - 2.7, y: flip(centerTop) - 1.7, width: 3.4, height: 3.4))
            }
        case .off:
            if let white = color("#FFFFFF") {
                ctx.setFillColor(white.copy(alpha: 0.18) ?? white)
                ctx.addPath(roundedPath(rect(x, top, w, h), h / 2))
                ctx.fillPath()
            }
        case .warn:
            guard let warn = color(HeatmapPalette.warn) else { return }
            let revealW = max(0, w * scene.hatch)
            guard revealW > 0.5 else { return }
            ctx.saveGState()
            ctx.addPath(roundedPath(rect(x, top, revealW, h), min(h / 2, revealW / 2)))
            ctx.clip()
            ctx.setFillColor(warn.copy(alpha: 0.22) ?? warn)
            ctx.fill(rect(x, top, w, h))
            ctx.setStrokeColor(warn.copy(alpha: 0.62) ?? warn)
            ctx.setLineWidth(1.1)
            let step: CGFloat = 4
            let off = scene.hatchShift.truncatingRemainder(dividingBy: step)
            var i = -h
            while i < w + h {
                ctx.move(to: CGPoint(x: x + i + off, y: flip(top + h)))
                ctx.addLine(to: CGPoint(x: x + i + off + h, y: flip(top)))
                ctx.strokePath()
                i += step
            }
            ctx.restoreGState()
        case .retry:
            guard let warn = color(HeatmapPalette.warn) else { return }
            ctx.setFillColor(warn.copy(alpha: 0.20) ?? warn)
            ctx.addPath(roundedPath(rect(x, top, w, h), h / 2))
            ctx.fillPath()
            ctx.saveGState()
            ctx.addPath(roundedPath(rect(x, top, w, h), h / 2))
            ctx.clip()
            let segW: CGFloat = 18
            let pos = x + (w + segW) * scene.sweep - segW
            let colors = [warn.copy(alpha: 0.15) ?? warn,
                          warn.copy(alpha: 0.95) ?? warn,
                          warn.copy(alpha: 0.15) ?? warn] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: colors, locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: pos, y: flip(centerTop)),
                                       end: CGPoint(x: pos + segW, y: flip(centerTop)),
                                       options: [])
            }
            ctx.restoreGState()
        }
    }

    // MARK: 工具

    private static func color(_ hex: String) -> CGColor? {
        StatTileRenderer.color(hex)
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
