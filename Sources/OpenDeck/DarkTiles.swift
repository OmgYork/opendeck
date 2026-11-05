import AppKit
import CoreGraphics
import CoreText
import Foundation
import StreamDockKit

// MARK: - 「暗夜仪表」统一画布语言(§6.33)
//
// 槽 4–8 的共享视觉语法:深底渐变 + 玻璃内衬 + 同色辉光。此前统计键是 Nord 粉彩
// 大色块、睡眠锁是饱和绿实心块,与整套「深底辉光」键面(鲸鱼娘/显示器动效)断裂。
// 全部渲染 upright,输出侧统一走 preRotated(与 StatTileRenderer 同规)。

/// 暗夜仪表共用绘制的调色板与几何常量
enum DarkTileStyle {
    static let bgTop = CGColor(srgbRed: 0.106, green: 0.125, blue: 0.169, alpha: 1)      // #1B202B
    static let bgBottom = CGColor(srgbRed: 0.059, green: 0.071, blue: 0.094, alpha: 1)   // #0F1218
    static let valueWhite = CGColor(srgbRed: 0.925, green: 0.937, blue: 0.957, alpha: 1) // #ECEFF4
    static let glassStroke = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
    static let trackAlpha: CGFloat = 0.10

    static let gpuAccent = CGColor(srgbRed: 0.302, green: 0.639, blue: 1, alpha: 1)      // #4DA3FF
    static let cpuAccent = CGColor(srgbRed: 0.247, green: 0.725, blue: 0.314, alpha: 1)  // #3FB950
    static let amber = CGColor(srgbRed: 0.941, green: 0.706, blue: 0.161, alpha: 1)      // #F0B429
    static let red = CGColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)        // #E5484D
    static let offGray = CGColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1)    // #8B949E

    /// 温度弧色映射:≤50° 绿 → 50–75° 渐变琥珀 → ≥78° 渐变红(连续插值,不做硬档位)
    static func tempColor(_ celsius: Double) -> CGColor {
        func lerp(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
            let ca = a.components!, cb = b.components!
            let clamped = min(max(t, 0), 1)
            return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * clamped,
                           green: ca[1] + (cb[1] - ca[1]) * clamped,
                           blue: ca[2] + (cb[2] - ca[2]) * clamped, alpha: 1)
        }
        if celsius <= 50 { return cpuAccent }
        if celsius <= 72 { return lerp(cpuAccent, amber, CGFloat((celsius - 50) / 22)) }
        return lerp(amber, red, CGFloat(min(max((celsius - 72) / 10, 0), 1)))
    }

    static func accent(for kind: StatKind, tempCelsius: Double?) -> CGColor {
        switch kind {
        case .gpu: return gpuAccent
        case .cpu: return cpuAccent
        case .temp: return tempColor(tempCelsius ?? 60)
        }
    }
}

/// 深底画布 + CoreText 直绘工具(文字在裸 CGContext 上必须走 CoreText,实测)
@MainActor
enum DarkTileCanvas {
    /// 统一底:垂直渐变 + 内衬玻璃描边。返回 upright 上下文(调用方继续画内容)
    static func beginCanvas(side: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [DarkTileStyle.bgTop, DarkTileStyle.bgBottom] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(side)), options: [])
        // 玻璃内衬:inset 圆角描边 + 顶部高光
        let inset: CGFloat = 5, cRadius: CGFloat = 15
        let rect = CGRect(x: inset, y: inset, width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2)
        ctx.setStrokeColor(DarkTileStyle.glassStroke)
        ctx.setLineWidth(1.5)
        ctx.strokePath() // 先空描一次路径占位(无路径时无害)
        let path = CGPath(roundedRect: rect, cornerWidth: cRadius, cornerHeight: cRadius, transform: nil)
        ctx.addPath(path)
        ctx.setStrokeColor(DarkTileStyle.glassStroke)
        ctx.strokePath()
        return ctx
    }

    /// upright → 设备 180° 预旋转(共用收尾)
    static func finishRotated(_ image: CGImage, side: Int, space: CGColorSpace?) -> CGImage? {
        guard let rotated = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        rotated.translateBy(x: CGFloat(side), y: CGFloat(side))
        rotated.rotate(by: .pi)
        rotated.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        return rotated.makeImage()
    }

    /// CoreText 居中/左上直绘 + 同色辉光(shadow)
    static func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight,
                         color: CGColor, rect: CGRect, ctx: CGContext,
                         align: CTTextAlignment = .center, glow: Bool = true, glowBlur: CGFloat = 5) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: roundedFont(size: size, weight: weight),
            .foregroundColor: color,
        ]
        if align == .center {
            attributes[.paragraphStyle] = {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                return style
            }()
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        if glow {
            ctx.setShadow(offset: .zero, blur: glowBlur, color: color)
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let bounds = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let textWidth = CGFloat(bounds)
        let textHeight = ascent + descent
        let originX: CGFloat = align == .center ? rect.midX - textWidth / 2 : rect.minX
        // CT 基线:给定垂直居中矩形,基线 = 中线 - descent 补偿
        let originY = rect.midY - textHeight / 2 + descent
        ctx.textPosition = CGPoint(x: originX, y: originY)
        CTLineDraw(line, ctx)
        ctx.setShadow(offset: .zero, blur: 0, color: nil) // 关辉光,不污染后续绘制
    }

    /// SF Rounded(仪表数字的圆润感;descriptor rounded 设计)
    static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return CTFontCreateWithFontDescriptor(rounded, size, nil)
        }
        return base
    }
}

// MARK: - 睡眠锁徽章(槽 5)

/// 睡眠锁专用渲染:深底 + 辉光挂锁,状态即视觉(ON 绿闭合 / OFF 灰开扣 / 未授权琥珀)。
/// 忽略键位底色配置——本键的设计语言由状态色驱动
@MainActor
enum SleepGuardTileRenderer {
    enum VisualState: Equatable {
        case on, off, unauthorized
        case unknown // 启动后尚未读到真实状态
    }

    static func accent(_ state: VisualState) -> CGColor {
        switch state {
        case .on: return DarkTileStyle.cpuAccent
        case .off, .unknown: return DarkTileStyle.offGray
        case .unauthorized: return DarkTileStyle.amber
        }
    }

    /// stateText 随状态;lockOpen 随 ON/OFF(unauthorized 画闭合锁 + 右下警示点)
    static func image(state: VisualState, side: Int = StreamDock293S.keySize(column: 0)) -> CGImage? {
        guard let ctx = DarkTileCanvas.beginCanvas(side: side) else { return nil }
        let s = CGFloat(side) / 112
        let accent = accent(state)

        let labelRect = CGRect(x: 14 * s, y: CGFloat(side) - 30 * s, width: 84 * s, height: 16 * s)
        DarkTileCanvas.drawText("睡眠锁", size: 12 * s, weight: .semibold,
                                color: accent.copy(alpha: 0.85)!,
                                rect: labelRect,
                                ctx: ctx, align: .left, glow: false)

        // 挂锁:锁体圆角矩形 + shackle 弧。open 时 shackle 上移并倾斜(开扣)
        let open = state == .off
        drawPadlock(ctx: ctx, center: CGPoint(x: 56 * s, y: 56 * s), scale: s,
                    accent: accent, shackleOpen: open, warn: state == .unauthorized)

        let statusText = state == .unauthorized ? "未授权" : (state == .unknown ? "…" : (state == .on ? "ON" : "OFF"))
        let statusRect = CGRect(x: 0, y: 12 * s, width: CGFloat(side), height: 18 * s)
        DarkTileCanvas.drawText(statusText, size: 12 * s, weight: .bold,
                                color: accent,
                                rect: statusRect,
                                ctx: ctx)

        guard let upright = ctx.makeImage() else { return nil }
        return DarkTileCanvas.finishRotated(upright, side: side, space: ctx.colorSpace)
    }

    /// 状态翻转过渡帧:shackle 开合 8 帧(shackle 垂直位移 + 角度插值)。
    /// from == to / unauthorized 涉及时返回 nil(直接换帧,不做开合动画)
    static func transitionFrames(from: VisualState, to: VisualState,
                                 side: Int = StreamDock293S.keySize(column: 0)) -> [CGImage]? {
        guard from != to, from != .unauthorized, to != .unauthorized else { return nil }
        let count = 8
        var frames: [CGImage] = []
        for step in 0..<count {
            let p = easeOutCubic(Double(step) / Double(count - 1))
            let startOpen = from == .off
            let openAmount = startOpen ? 1 - p : p // 闭合方向 vs 开启方向
            guard let image = image(state: to, side: side, shackleOverride: openAmount) else { continue }
            frames.append(image)
        }
        return frames.isEmpty ? nil : frames
    }

    /// shackleOverride: nil = 按 state 画;0..1 = 开扣程度(过渡帧插值用)
    private static func image(state: VisualState, side: Int, shackleOverride: Double?) -> CGImage? {
        guard let ctx = DarkTileCanvas.beginCanvas(side: side) else { return nil }
        let s = CGFloat(side) / 112
        let accent = accent(state)
        let open = shackleOverride.map { $0 > 0.5 } ?? (state == .off)

        let labelRect2 = CGRect(x: 14 * s, y: CGFloat(side) - 30 * s, width: 84 * s, height: 16 * s)
        DarkTileCanvas.drawText("睡眠锁", size: 12 * s, weight: .semibold,
                                color: accent.copy(alpha: 0.85)!,
                                rect: labelRect2,
                                ctx: ctx, align: .left, glow: false)
        let padlockCenter = CGPoint(x: 56 * s, y: 56 * s)
        let shackleLift: CGFloat = shackleOverride.map { CGFloat($0) * 6 * s } ?? (open ? 4 * s : 0)
        drawPadlock(ctx: ctx, center: padlockCenter, scale: s,
                    accent: accent, shackleOpen: open,
                    warn: state == .unauthorized,
                    shackleLift: shackleLift)
        DarkTileCanvas.drawText(state == .unauthorized ? "未授权" : (state == .on ? "ON" : "OFF"),
                                size: 12 * s, weight: .bold,
                                color: accent,
                                rect: CGRect(x: 0, y: 12 * s, width: CGFloat(side), height: 18 * s),
                                ctx: ctx)
        guard let upright = ctx.makeImage() else { return nil }
        return DarkTileCanvas.finishRotated(upright, side: side, space: ctx.colorSpace)
    }

    /// 挂锁几何:锁体 30×24 圆角矩形,shackle 为上拱弧;辉光 = 同色 shadow
    private static func drawPadlock(ctx: CGContext, center: CGPoint, scale: CGFloat,
                                    accent: CGColor, shackleOpen: Bool, warn: Bool,
                                    shackleLift: CGFloat = 0) {
        let bodyW: CGFloat = 30 * scale, bodyH: CGFloat = 24 * scale
        let bodyRect = CGRect(x: center.x - bodyW / 2, y: center.y - bodyH / 2 - 4 * scale,
                              width: bodyW, height: bodyH)
        ctx.setShadow(offset: .zero, blur: 7, color: accent)
        ctx.setFillColor(accent)
        let body = CGPath(roundedRect: bodyRect, cornerWidth: 5 * scale, cornerHeight: 5 * scale, transform: nil)
        ctx.addPath(body)
        ctx.fillPath()

        // 锁孔(深底挖色)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setFillColor(DarkTileStyle.bgBottom)
        ctx.fillEllipse(in: CGRect(x: center.x - 3.5 * scale, y: bodyRect.midY - 3.5 * scale + 1 * scale,
                                   width: 7 * scale, height: 7 * scale))
        ctx.fill(CGRect(x: center.x - 1.5 * scale, y: bodyRect.minY + 3 * scale,
                        width: 3 * scale, height: 7 * scale))

        // shackle:开扣时上移 + 收窄(几何插值足够传达,不做真旋转)
        let lineWidth = 4.5 * scale
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: 7, color: accent)
        let lift = shackleLift
        let halfGap: CGFloat = (shackleOpen ? 6.5 : 9) * scale
        let archTop = bodyRect.maxY + (shackleOpen ? 4 * scale : 8 * scale) + lift
        ctx.move(to: CGPoint(x: center.x - halfGap, y: bodyRect.maxY - 1 * scale))
        ctx.addArc(center: CGPoint(x: center.x, y: archTop),
                   radius: halfGap, startAngle: .pi, endAngle: 0, clockwise: false)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        if warn {
            // 右下警示角标:琥珀圆 + 感叹
            let warnCenter = CGPoint(x: center.x + 17 * scale, y: center.y - 17 * scale)
            ctx.setFillColor(DarkTileStyle.amber)
            ctx.fillEllipse(in: CGRect(x: warnCenter.x - 7 * scale, y: warnCenter.y - 7 * scale,
                                       width: 14 * scale, height: 14 * scale))
            DarkTileCanvas.drawText("!", size: 11 * scale, weight: .bold,
                                    color: DarkTileStyle.bgBottom,
                                    rect: CGRect(x: warnCenter.x - 7 * scale, y: warnCenter.y - 8 * scale,
                                                 width: 14 * scale, height: 16 * scale),
                                    ctx: ctx, glow: false)
        }
    }

    static func easeOutCubic(_ p: Double) -> Double {
        1 - pow(1 - min(max(p, 0), 1), 3)
    }
}

// MARK: - 媒体徽章(槽 4 及全部 mediaKey 键)

/// 媒体键专用渲染:深底 + 细辉光环 + 语义符号(白 + accent 辉光)。
/// mediaKey 六种全覆盖;忽略键位底色配置
@MainActor
enum MediaTileRenderer {
    static func image(kind: String, side: Int = StreamDock293S.keySize(column: 0)) -> CGImage? {
        guard let ctx = DarkTileCanvas.beginCanvas(side: side) else { return nil }
        let s = CGFloat(side) / 112
        let accent = CGColor(srgbRed: 0, green: 0.675, blue: 0.8, alpha: 1) // #00ACC

        // 细辉光环
        ctx.setStrokeColor(accent.copy(alpha: 0.22)!)
        ctx.setLineWidth(2)
        ctx.setShadow(offset: .zero, blur: 6, color: accent)
        ctx.strokeEllipse(in: CGRect(x: 18 * s, y: 18 * s, width: 76 * s, height: 76 * s))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        let white = DarkTileStyle.valueWhite
        switch kind {
        case "playPause":
            // 双符等权:播放三角 + 暂停双条(系统播放态不可知,等权是诚实设计)
            drawPlayTriangle(ctx: ctx, center: CGPoint(x: 47 * s, y: 58 * s), size: 17 * s, color: white)
            drawPauseBars(ctx: ctx, center: CGPoint(x: 68 * s, y: 58 * s), size: 17 * s, color: white)
        case "next":
            drawPlayTriangle(ctx: ctx, center: CGPoint(x: 52 * s, y: 58 * s), size: 16 * s, color: white)
            ctx.setFillColor(white)
            ctx.fill(CGRect(x: 64 * s, y: 58 * s - 11 * s, width: 4.5 * s, height: 22 * s))
        case "previous":
            ctx.setFillColor(white)
            ctx.fill(CGRect(x: 43.5 * s, y: 58 * s - 11 * s, width: 4.5 * s, height: 22 * s))
            drawPlayTriangle(ctx: ctx, center: CGPoint(x: 60 * s, y: 58 * s), size: 16 * s, color: white, flipped: true)
        case "volumeUp", "volumeDown", "mute":
            drawSpeaker(ctx: ctx, center: CGPoint(x: 47 * s, y: 58 * s), scale: s, color: white)
            let chevronY = 58 * s
            ctx.setStrokeColor(white)
            ctx.setLineWidth(3.5 * s)
            ctx.setLineCap(.round)
            switch kind {
            case "volumeUp":
                ctx.move(to: CGPoint(x: 64 * s, y: chevronY - 6 * s))
                ctx.addLine(to: CGPoint(x: 70 * s, y: chevronY))
                ctx.addLine(to: CGPoint(x: 64 * s, y: chevronY + 6 * s))
            case "volumeDown":
                ctx.move(to: CGPoint(x: 64 * s, y: chevronY + 6 * s))
                ctx.addLine(to: CGPoint(x: 70 * s, y: chevronY))
                ctx.addLine(to: CGPoint(x: 64 * s, y: chevronY - 6 * s))
            case "mute":
                ctx.move(to: CGPoint(x: 63 * s, y: chevronY - 7 * s))
                ctx.addLine(to: CGPoint(x: 73 * s, y: chevronY + 7 * s))
            default: break
            }
            ctx.strokePath()
        default:
            break
        }

        guard let upright = ctx.makeImage() else { return nil }
        return DarkTileCanvas.finishRotated(upright, side: side, space: ctx.colorSpace)
    }

    private static func drawPlayTriangle(ctx: CGContext, center: CGPoint, size: CGFloat, color: CGColor, flipped: Bool = false) {
        ctx.setShadow(offset: .zero, blur: 6, color: color)
        ctx.setFillColor(color)
        let direction: CGFloat = flipped ? -1 : 1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - direction * size / 2, y: center.y + size / 2))
        path.addLine(to: CGPoint(x: center.x - direction * size / 2, y: center.y - size / 2))
        path.addLine(to: CGPoint(x: center.x + direction * size / 2, y: center.y))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private static func drawPauseBars(ctx: CGContext, center: CGPoint, size: CGFloat, color: CGColor) {
        ctx.setShadow(offset: .zero, blur: 6, color: color)
        ctx.setFillColor(color)
        let barW = size / 3.4
        ctx.fill(CGRect(x: center.x - size / 2, y: center.y - size / 2, width: barW, height: size))
        ctx.fill(CGRect(x: center.x + size / 2 - barW, y: center.y - size / 2, width: barW, height: size))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private static func drawSpeaker(ctx: CGContext, center: CGPoint, scale: CGFloat, color: CGColor) {
        ctx.setShadow(offset: .zero, blur: 5, color: color)
        ctx.setFillColor(color)
        let body = CGMutablePath()
        // 小矩形 + 喇叭口梯形
        body.move(to: CGPoint(x: center.x - 12 * scale, y: center.y + 4 * scale))
        body.addLine(to: CGPoint(x: center.x - 5 * scale, y: center.y + 4 * scale))
        body.addLine(to: CGPoint(x: center.x + 2 * scale, y: center.y + 11 * scale))
        body.addLine(to: CGPoint(x: center.x + 2 * scale, y: center.y - 11 * scale))
        body.addLine(to: CGPoint(x: center.x - 5 * scale, y: center.y - 4 * scale))
        body.addLine(to: CGPoint(x: center.x - 12 * scale, y: center.y - 4 * scale))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
}
