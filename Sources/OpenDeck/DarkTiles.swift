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
// MARK: - 合盖模式徽章(槽 5;原「睡眠锁」——锁的意象有歧义,§6.40 改为合盖+灯缝)

/// 合盖模式键渲染:深底玻璃 + 合盖笔记本剪影,盖缝透光 = 机器还醒着。
/// 事实源 pmset SleepDisabled(经 AppModel.sleepGuardEnabled);
/// 文案直接陈述合盖行为(合盖不休眠/合盖休眠),不用 ON/OFF(挂在「睡眠锁」名下有歧义)。
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

    static func statusText(for state: VisualState) -> String {
        switch state {
        case .on: return "合盖不休眠"
        case .off: return "合盖休眠"
        case .unauthorized: return "未授权"
        case .unknown: return "…"
        }
    }

    /// 静息帧
    static func image(state: VisualState, side: Int = StreamDock293S.keySize(column: 0)) -> CGImage? {
        render(state: state, side: side, lightAmount: nil)
    }

    /// 状态翻转过渡帧:on↔off = 灯缝渐熄/渐亮 8 帧(easeInOut);涉 unauthorized/unknown 直接换帧
    static func transitionFrames(from: VisualState, to: VisualState,
                                 side: Int = StreamDock293S.keySize(column: 0)) -> [CGImage]? {
        guard from != to, from != .unauthorized, to != .unauthorized,
              from != .unknown, to != .unknown else { return nil }
        let count = 8
        var frames: [CGImage] = []
        for step in 0..<count {
            let p = SleepGuardTileRenderer.easeOutCubic(Double(step + 1) / Double(count))
            // 灯缝强度:from 的亮度 → to 的亮度线性插值(on=1/off=0)
            let fromLight: CGFloat = from == .on ? 1 : 0
            let toLight: CGFloat = to == .on ? 1 : 0
            let light = fromLight + (toLight - fromLight) * CGFloat(p)
            if let image = render(state: to, side: side, lightAmount: light) {
                frames.append(image)
            }
        }
        return frames.isEmpty ? nil : frames
    }

    /// lightAmount: 缝光强度 0..1(过渡插值);nil = 按 state 取(on=1/其余=0)
    private static func render(state: VisualState, side: Int, lightAmount: CGFloat?) -> CGImage? {
        guard let ctx = DarkTileCanvas.beginCanvas(side: side) else { return nil }
        let s = CGFloat(side) / 112
        let accent = accent(state)
        let awake = state == .on
        let light = lightAmount ?? (awake ? 1 : 0)

        let labelRect = CGRect(x: 14 * s, y: CGFloat(side) - 30 * s, width: 84 * s, height: 16 * s)
        DarkTileCanvas.drawText("合盖模式", size: 12 * s, weight: .semibold,
                                color: accent.copy(alpha: 0.85)!,
                                rect: labelRect,
                                ctx: ctx, align: .left, glow: false)

        drawClamshell(ctx: ctx, center: CGPoint(x: 56 * s, y: 52 * s), scale: s,
                      accent: accent, awake: awake,
                      warn: state == .unauthorized, lightAmount: Double(light))

        let statusRect = CGRect(x: 0, y: 12 * s, width: CGFloat(side), height: 18 * s)
        DarkTileCanvas.drawText(statusText(for: state), size: 12 * s, weight: .bold,
                                color: accent,
                                rect: statusRect,
                                ctx: ctx)

        guard let upright = ctx.makeImage() else { return nil }
        return DarkTileCanvas.finishRotated(upright, side: side, space: ctx.colorSpace)
    }

    static func easeOutCubic(_ p: Double) -> Double {
        1 - pow(1 - min(max(p, 0), 1), 3)
    }

    /// 合盖笔记本:盖子(横圆角条)+ 底座(宽薄条),中缝为状态光源。
    /// awake = 盖子带 accent 微光;lightAmount = 缝光强度(过渡插值)。
    /// warn = 未授权琥珀角标。
    private static func drawClamshell(ctx: CGContext, center: CGPoint, scale: CGFloat,
                                      accent: CGColor, awake: Bool, warn: Bool,
                                      lightAmount: Double) {
        let lidW: CGFloat = 40 * scale, lidH: CGFloat = 11 * scale
        let baseW: CGFloat = 48 * scale, baseH: CGFloat = 6 * scale
        let lidRect = CGRect(x: center.x - lidW / 2, y: center.y - 4 * scale,
                             width: lidW, height: lidH)
        let baseRect = CGRect(x: center.x - baseW / 2, y: lidRect.minY - 5 * scale,
                              width: baseW, height: baseH)

        // 底座(dim 白描边)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30))
        ctx.setLineWidth(1.5 * scale)
        ctx.addPath(CGPath(roundedRect: baseRect, cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil))
        ctx.strokePath()

        // 盖子:awake 时 accent 微填充 + 辉光描边(活着);off 暗灰
        let lidColor = awake ? accent : DarkTileStyle.offGray
        if awake {
            ctx.setShadow(offset: .zero, blur: 6, color: lidColor)
        }
        ctx.setFillColor(lidColor.copy(alpha: awake ? 0.30 : 0.22)!)
        let lidPath = CGPath(roundedRect: lidRect, cornerWidth: 5 * scale, cornerHeight: 5 * scale, transform: nil)
        ctx.addPath(lidPath)
        ctx.fillPath()
        ctx.setStrokeColor(lidColor)
        ctx.setLineWidth(2 * scale)
        ctx.addPath(lidPath)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // 盖缝透光:盖与底座之间的缝,亮线 + 大范围辉光(状态的核心可读元素)
        if lightAmount > 0.01 {
            ctx.setAlpha(CGFloat(min(max(lightAmount, 0), 1)))
            ctx.setShadow(offset: .zero, blur: 9, color: accent)
            ctx.setFillColor(accent)
            ctx.fill(CGRect(x: lidRect.minX + 4 * scale, y: lidRect.minY - 3.5 * scale,
                            width: lidW - 8 * scale, height: 2 * scale))
            ctx.setAlpha(1)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }

        if warn {
            let warnCenter = CGPoint(x: center.x + 21 * scale, y: center.y - 19 * scale)
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

// MARK: - 导航卡尺(槽 14/15 保留键,§6.34)

/// 场景/页导航键专用渲染:场景 = 层叠卡片(切换 = 卡片交换),页面 = 竖排页点滑轨
/// (翻页 = 点阵滑移)。保留槽强制导航动作,用户在普通键位绑的同款动作同享此设计
@MainActor
enum NavTileRenderer {
    enum Kind: Equatable {
        case scene
        case page

        init?(action: KeyAction?) {
            switch action {
            case .nextScene, .previousScene: self = .scene
            case .nextPage, .previousPage: self = .page
            default: return nil
            }
        }

        var label: String { self == .scene ? "场景" : "页面" }
    }

    static func accent(for kind: Kind) -> CGColor {
        kind == .scene ? DarkTileStyle.gpuAccent : DarkTileStyle.offGray
    }

    /// 静息帧。页键带真实页态:pageCount = 当前场景页数,pageIndex = 当前页(辉光点)。
    /// glowOffset: 页键过渡用——辉光点位置 = pageIndex + glowOffset(模页数),0..1 一档
    static func image(kind: Kind, side: Int = StreamDock293S.keySize(column: 0),
                      pageCount: Int = 0, pageIndex: Int = 0, glowOffset: Double? = nil) -> CGImage? {
        render(kind: kind, side: side, slide: 0,
               pageCount: pageCount, pageIndex: pageIndex, glowOffset: glowOffset)
    }

    /// 方向过渡帧:6 帧。场景键 = 卡片滑移包络(出去又回来);页键 = 辉光点沿轨滑移一档
    /// (循环翻页绕轨端,模页数)。final 由调用方给(新页态静息帧),帧序列不含静息
    static func transitionFrames(kind: Kind, offset: Int, pageCount: Int = 0, fromIndex: Int = 0,
                                 side: Int = StreamDock293S.keySize(column: 0)) -> [CGImage]? {
        guard offset != 0 else { return nil }
        let count = 6
        var frames: [CGImage] = []
        for step in 0..<count {
            let p = SleepGuardTileRenderer.easeOutCubic(Double(step + 1) / Double(count))
            let image: CGImage?
            if kind == .page, pageCount > 0 {
                image = render(kind: kind, side: side, slide: 0,
                               pageCount: pageCount, pageIndex: fromIndex,
                               glowOffset: Double(offset) * p)
            } else {
                // 场景键:滑移包络(sin,出去又回来)
                let envelope = sin(p * .pi)
                let slide = CGFloat(offset) * 14 * CGFloat(envelope)
                image = render(kind: kind, side: side, slide: slide)
            }
            if let image { frames.append(image) }
        }
        return frames.isEmpty ? nil : frames
    }

    /// slide:场景卡内容整体位移(px,含方向);0 = 静息
    private static func render(kind: Kind, side: Int, slide: CGFloat,
                               pageCount: Int = 0, pageIndex: Int = 0, glowOffset: Double? = nil) -> CGImage? {
        guard let ctx = DarkTileCanvas.beginCanvas(side: side) else { return nil }
        let s = CGFloat(side) / 112
        let accent = accent(for: kind)
        let dx = slide * (kind == .scene ? 1 : 0)
        let dy = slide * (kind == .page ? 1 : 0)

        DarkTileCanvas.drawText(kind.label, size: 12 * s, weight: .semibold,
                                color: accent.copy(alpha: 0.85)!,
                                rect: CGRect(x: 14 * s, y: CGFloat(side) - 30 * s, width: 84 * s, height: 16 * s),
                                ctx: ctx, align: .left, glow: false)

        switch kind {
        case .scene:
            drawSceneCards(ctx: ctx, center: CGPoint(x: 56 * s + dx, y: 56 * s + dy), scale: s, accent: accent)
        case .page:
            let count = max(pageCount, 1)
            let index = min(max(pageIndex, 0), count - 1)
            drawPageDots(ctx: ctx, center: CGPoint(x: 56 * s + dx, y: 56 * s + dy), scale: s,
                         accent: accent, pageCount: count, currentIndex: index, glowOffset: glowOffset)
        }

        guard let upright = ctx.makeImage() else { return nil }
        return DarkTileCanvas.finishRotated(upright, side: side, space: ctx.colorSpace)
    }

    /// 层叠卡片:后卡(dim)右下偏移,前卡(accent 辉光)居中——「多场景堆叠」的直觉像
    private static func drawSceneCards(ctx: CGContext, center: CGPoint, scale: CGFloat, accent: CGColor) {
        let cardW = 34 * scale, cardH = 30 * scale
        // 后卡
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
        let back = CGPath(roundedRect: CGRect(x: center.x - cardW / 2 + 7 * scale, y: center.y - cardH / 2 - 6 * scale,
                                              width: cardW, height: cardH),
                          cornerWidth: 6 * scale, cornerHeight: 6 * scale, transform: nil)
        ctx.addPath(back)
        ctx.fillPath()
        // 前卡(辉光描边 + 微填充)
        ctx.setShadow(offset: .zero, blur: 7, color: accent)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(2.5 * scale)
        let front = CGPath(roundedRect: CGRect(x: center.x - cardW / 2 - 3 * scale, y: center.y - cardH / 2 + 2 * scale,
                                               width: cardW, height: cardH),
                           cornerWidth: 6 * scale, cornerHeight: 6 * scale, transform: nil)
        ctx.addPath(front)
        ctx.strokePath()
        ctx.setFillColor(accent.copy(alpha: 0.16)!)
        ctx.addPath(front)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // 前卡中心小圆点(场景芯)
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: center.x - 3 * scale - 3 * scale, y: center.y + 2 * scale - 3 * scale,
                                   width: 6 * scale, height: 6 * scale))
    }

    /// 页点滑轨:每页一枚点(轨距随页数自适应),当前页辉光实心、其余空心描边。
    /// 阅读序 = 页 1 在顶部(CG 高 y),glowOffset 非 nil 时辉光点沿轨滑移一档
    /// (循环翻页跨端按锯齿折返,视觉连续)
    private static func drawPageDots(ctx: CGContext, center: CGPoint, scale: CGFloat, accent: CGColor,
                                     pageCount: Int, currentIndex: Int, glowOffset: Double?) {
        let usable = 58 * scale                       // 上下可用轨长
        let spacing = min(13 * scale, usable / CGFloat(max(pageCount, 1)))
        let railTop = center.y + spacing * CGFloat(pageCount - 1) / 2 // CG 高 y = 视觉顶

        func dotY(_ position: Double) -> CGFloat {
            railTop - spacing * CGFloat(position)     // 索引增 → 视觉下移
        }

        for page in 0..<pageCount {
            guard page != currentIndex else { continue } // 辉光点最后画(盖在描边点上)
            let dotCenter = CGPoint(x: center.x, y: dotY(Double(page)))
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30))
            ctx.setLineWidth(1.5 * scale)
            ctx.strokeEllipse(in: CGRect(x: dotCenter.x - 4.5 * scale, y: dotCenter.y - 4.5 * scale,
                                         width: 9 * scale, height: 9 * scale))
        }
        // 辉光点(当前页,或过渡中的滑移位;锯齿折返处理循环翻页的跨端)
        let virtual = Double(currentIndex) + (glowOffset ?? 0)
        let folded: Double
        if let glowOffset, glowOffset.truncatingRemainder(dividingBy: 1) != 0 {
            let period = Double(max(pageCount - 1, 1)) * 2
            var v = virtual.truncatingRemainder(dividingBy: period)
            if v < 0 { v += period }
            folded = v <= Double(pageCount - 1) ? v : period - v
        } else {
            folded = virtual
        }
        let glowCenter = CGPoint(x: center.x, y: dotY(folded))
        ctx.setShadow(offset: .zero, blur: 7, color: accent)
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: glowCenter.x - 6 * scale, y: glowCenter.y - 6 * scale,
                                   width: 12 * scale, height: 12 * scale))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
}

// MARK: - 图像模式徽章(§6.39,picModeToggle 动效键)

/// 图像模式 toggle 键渲染:深底玻璃 + 当前模式符号(玩家 🎮 蓝 / 阅读 绿)
/// + 底部目标模式提示条。读 ~/.cache/lg_pic_mode(缺失/其它值 = "--" 待切换)
@MainActor
enum PicModeTileRenderer {
    enum Mode: Equatable {
        case game
        case read
        case unknown

        init(stateFile: String?) {
            switch stateFile {
            case "game": self = .game
            case "read": self = .read
            default: self = .unknown
            }
        }

        var accent: CGColor {
            switch self {
            case .game: return DarkTileStyle.gpuAccent
            case .read: return DarkTileStyle.cpuAccent
            case .unknown: return DarkTileStyle.offGray
            }
        }

        var label: String {
            switch self {
            case .game: return "玩家1"
            case .read: return "阅读"
            case .unknown: return "--"
            }
        }

        /// toggle 目标(unknown 首按落 game)
        var flipped: Mode {
            switch self {
            case .game: return .read
            case .read: return .game
            case .unknown: return .game
            }
        }
    }

    static func currentStateFile() -> String? {
        MonitorPicModeStateFile.read()
    }

    /// 静息帧:当前模式符号 + 底部「↔ 目标」提示
    static func image(mode: Mode, side: Int = StreamDock293S.keySize(column: 0)) -> CGImage? {
        render(mode: mode, side: side, slide: 0)
    }

    /// 切换过渡帧:6 帧横向扫动(内容从当前侧滑出、目标侧滑入,sin 包络)
    static func transitionFrames(from: Mode, to: Mode,
                                 side: Int = StreamDock293S.keySize(column: 0)) -> [CGImage]? {
        guard from != to else { return nil }
        let count = 6
        var frames: [CGImage] = []
        for step in 0..<count {
            let p = SleepGuardTileRenderer.easeOutCubic(Double(step + 1) / Double(count))
            let envelope = sin(p * .pi)
            let direction: CGFloat = to == .read ? -1 : 1 // 阅读↔玩家 符号横滑方向感
            if let image = render(mode: to, side: side, slide: 26 * direction * CGFloat(envelope),
                                  crossFadeFrom: from, fade: CGFloat(envelope)) {
                frames.append(image)
            }
        }
        return frames.isEmpty ? nil : frames
    }

    /// slide:符号横滑位移;crossFadeFrom/fade:切换时旧符号残影淡出
    private static func render(mode: Mode, side: Int, slide: CGFloat,
                               crossFadeFrom: Mode? = nil, fade: CGFloat = 0) -> CGImage? {
        guard let ctx = DarkTileCanvas.beginCanvas(side: side) else { return nil }
        let s = CGFloat(side) / 112
        let accent = mode.accent

        DarkTileCanvas.drawText("图像模式", size: 12 * s, weight: .semibold,
                                color: accent.copy(alpha: 0.85)!,
                                rect: CGRect(x: 14 * s, y: CGFloat(side) - 30 * s, width: 84 * s, height: 16 * s),
                                ctx: ctx, align: .left, glow: false)

        // 当前模式符号(横滑位移 + 辉光)
        let symbolCenter = CGPoint(x: 56 * s + slide, y: 54 * s)
        switch mode {
        case .game:
            drawGamepadGlyph(ctx: ctx, center: symbolCenter, scale: s, color: accent)
        case .read:
            drawBookGlyph(ctx: ctx, center: symbolCenter, scale: s, color: accent)
        case .unknown:
            DarkTileCanvas.drawText("--", size: 26 * s, weight: .bold,
                                    color: DarkTileStyle.offGray,
                                    rect: CGRect(x: 0, y: 40 * s, width: CGFloat(side), height: 30 * s),
                                    ctx: ctx)
        }

        // 切换中的旧符号残影(淡出)
        if let crossFadeFrom, fade > 0.01 {
            ctx.setAlpha(0.35 * (1 - fade))
            let ghostCenter = CGPoint(x: 56 * s - slide, y: 54 * s)
            switch crossFadeFrom {
            case .game:
                drawGamepadGlyph(ctx: ctx, center: ghostCenter, scale: s, color: DarkTileStyle.offGray)
            case .read:
                drawBookGlyph(ctx: ctx, center: ghostCenter, scale: s, color: DarkTileStyle.offGray)
            case .unknown:
                break
            }
            ctx.setAlpha(1)
        }

        // 底部提示:↔ 目标模式(toggle 的另一半)
        let target = mode.flipped
        DarkTileCanvas.drawText("↔ \(target.label)", size: 12 * s, weight: .medium,
                                color: DarkTileStyle.valueWhite.copy(alpha: 0.55)!,
                                rect: CGRect(x: 0, y: 12 * s, width: CGFloat(side), height: 18 * s),
                                ctx: ctx, glow: false)

        guard let upright = ctx.makeImage() else { return nil }
        return DarkTileCanvas.finishRotated(upright, side: side, space: ctx.colorSpace)
    }

    /// 手柄符号:圆角胶囊 + 十字键 + 双钮(自绘,无 SF Symbol 依赖)
    private static func drawGamepadGlyph(ctx: CGContext, center: CGPoint, scale: CGFloat, color: CGColor) {
        ctx.setShadow(offset: .zero, blur: 7, color: color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2.5 * scale)
        let body = CGPath(roundedRect: CGRect(x: center.x - 17 * scale, y: center.y - 12 * scale,
                                              width: 34 * scale, height: 24 * scale),
                          cornerWidth: 10 * scale, cornerHeight: 10 * scale, transform: nil)
        ctx.addPath(body)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // 十字键(左)
        ctx.setFillColor(color)
        let cx = center.x - 8 * scale, cy = center.y
        ctx.fill(CGRect(x: cx - 1.5 * scale, y: cy - 5 * scale, width: 3 * scale, height: 10 * scale))
        ctx.fill(CGRect(x: cx - 5 * scale, y: cy - 1.5 * scale, width: 10 * scale, height: 3 * scale))
        // 双钮(右)
        ctx.fillEllipse(in: CGRect(x: center.x + 7 * scale, y: cy + 1 * scale, width: 3.5 * scale, height: 3.5 * scale))
        ctx.fillEllipse(in: CGRect(x: center.x + 10 * scale, y: cy - 4 * scale, width: 3.5 * scale, height: 3.5 * scale))
    }

    /// 书本符号:翻开的双页(自绘)
    private static func drawBookGlyph(ctx: CGContext, center: CGPoint, scale: CGFloat, color: CGColor) {
        ctx.setShadow(offset: .zero, blur: 7, color: color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2.5 * scale)
        ctx.setLineJoin(.round)
        // 左页
        ctx.move(to: CGPoint(x: center.x, y: center.y - 10 * scale))
        ctx.addCurve(to: CGPoint(x: center.x - 14 * scale, y: center.y - 8 * scale),
                     control1: CGPoint(x: center.x - 6 * scale, y: center.y - 13 * scale),
                     control2: CGPoint(x: center.x - 10 * scale, y: center.y - 11 * scale))
        ctx.addLine(to: CGPoint(x: center.x - 14 * scale, y: center.y + 9 * scale))
        ctx.addCurve(to: CGPoint(x: center.x, y: center.y + 10 * scale),
                     control1: CGPoint(x: center.x - 10 * scale, y: center.y + 7 * scale),
                     control2: CGPoint(x: center.x - 6 * scale, y: center.y + 8 * scale))
        ctx.strokePath()
        // 右页(镜像)
        ctx.move(to: CGPoint(x: center.x, y: center.y - 10 * scale))
        ctx.addCurve(to: CGPoint(x: center.x + 14 * scale, y: center.y - 8 * scale),
                     control1: CGPoint(x: center.x + 6 * scale, y: center.y - 13 * scale),
                     control2: CGPoint(x: center.x + 10 * scale, y: center.y - 11 * scale))
        ctx.addLine(to: CGPoint(x: center.x + 14 * scale, y: center.y + 9 * scale))
        ctx.addCurve(to: CGPoint(x: center.x, y: center.y + 10 * scale),
                     control1: CGPoint(x: center.x + 10 * scale, y: center.y + 7 * scale),
                     control2: CGPoint(x: center.x + 6 * scale, y: center.y + 8 * scale))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
}
