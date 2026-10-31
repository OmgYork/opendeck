import CoreGraphics
import Foundation

// MARK: - 语义模型

/// 显示器输入源。动效的母题是「信号在两个源之间搬家」,不是显示器开关:
/// 槽位 1 的 Toggle Monitor 实际切换 LG 27GP95U 的 DP(Mac)↔ HDMI1(PC)。
nonisolated enum MonitorInputSource: String, Codable, Hashable, CaseIterable {
    case mac
    case pc

    /// 源色:冷蓝 = Mac,暖橙 = PC。112px 键面上,颜色比文字更早被读到。
    var accentHex: String {
        switch self {
        case .mac: return "#4DA3FF"
        case .pc: return "#FFA94D"
        }
    }

    var label: String {
        switch self {
        case .mac: return "Mac"
        case .pc: return "PC"
        }
    }

    var opposite: MonitorInputSource { self == .mac ? .pc : .mac }

    /// 状态文件 `~/.cache/lg_input` 的取值("mac" / "pc",带换行);路径见 MonitorInputStateFile
    static func parse(_ text: String) -> MonitorInputSource? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mac": return .mac
        case "pc": return .pc
        default: return nil
        }
    }
}

/// 动效节奏。每一步都落在整数帧上,渲染完全确定:
/// 预览页导出的帧 = 设备上真实下发的帧,不存在「预览好看、上机变样」。
enum MonitorIconTiming {
    static let transitionFrameCount = 12
    static let transitionFPS: Double = 12
    static let ambientFrameCount = 6
    static let ambientFPS: Double = 6
    /// 静息状态下每隔多久跑一次「信号包」呼吸(秒)
    static let ambientPeriod: TimeInterval = 8

    static var transitionFrameDuration: TimeInterval { 1 / transitionFPS }
    static var ambientFrameDuration: TimeInterval { 1 / ambientFPS }
}

enum MonitorIconFrame: Equatable {
    case idle(MonitorInputSource)
    case ambient(MonitorInputSource, frame: Int)
    case transition(from: MonitorInputSource, to: MonitorInputSource, frame: Int, reverted: Bool)
}

// MARK: - 渲染器

/// 112×112 键面渲染。设计坐标固定为 112×112、y 向下,内部按 size/112 等比缩放。
/// 无文字:所有语义由形状、位置、颜色与运动承载(小键面上文字会先糊成一团)。
enum MonitorInputIconRenderer {
    static let designSize: CGFloat = 112

    /// - Parameter prerotated: 设备以 180° 显示,下发帧需预旋转;预览导出一律传 false。
    static func image(size: Int, frame: MonitorIconFrame, prerotated: Bool = true) -> CGImage? {
        guard size > 0 else { return nil }
        let side = CGFloat(size)
        let scale = side / designSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // 设计坐标 y 向下:一次 translate+scale 之后,下面所有坐标都按「左上原点」写。
        ctx.translateBy(x: 0, y: side)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        draw(scene(for: frame), in: ctx)

        guard let upright = ctx.makeImage() else { return nil }
        return prerotated ? rotated180(upright) : upright
    }

    // MARK: 场景状态(把时间轴翻译成一组可插值的量)

    private struct Scene {
        var from: MonitorInputSource
        var to: MonitorInputSource
        /// 0 = 旧源主导,1 = 新源主导(光晕/LED/屏幕底色交叉淡化)
        var mix: CGFloat
        var fromChip: CGFloat
        var toChip: CGFloat
        var fromChipScale: CGFloat
        var toChipScale: CGFloat
        var fromBeam: CGFloat
        var toBeam: CGFloat
        var toBeamDraw: CGFloat
        var led: CGFloat
        var errorBlink: CGFloat
        /// 屏幕内容
        var screenSource: MonitorInputSource
        var screenAlpha: CGFloat
        var screenScale: CGFloat
        var screenDim: CGFloat
        var screenDark: CGFloat
        var screenFlash: CGFloat
        var screenOffsetX: CGFloat
        var sweep: CGFloat?
        var sweepAlpha: CGFloat
        var orb: Orb?
        var splash: Splash?
        var ambient: CGFloat?
        var arrival: CGFloat
    }

    private struct Orb {
        var point: CGPoint
        var scale: CGFloat
        var alpha: CGFloat
        var trail: [CGPoint]
    }

    private struct Splash {
        var point: CGPoint
        var radius: CGFloat
        var alpha: CGFloat
    }

    private static func scene(for frame: MonitorIconFrame) -> Scene {
        switch frame {
        case .idle(let source):
            return idleScene(source)
        case .ambient(let source, let index):
            return ambientScene(source, frame: max(0, min(MonitorIconTiming.ambientFrameCount - 1, index)))
        case .transition(let from, let to, let index, let reverted):
            return transitionScene(from: from, to: to,
                                   frame: max(0, min(MonitorIconTiming.transitionFrameCount - 1, index)),
                                   reverted: reverted)
        }
    }

    private static func idleScene(_ source: MonitorInputSource) -> Scene {
        Scene(from: source, to: source, mix: 1,
              fromChip: 0, toChip: 1, fromChipScale: 1, toChipScale: 1,
              fromBeam: 0, toBeam: 1, toBeamDraw: 1,
              led: 1, errorBlink: 0,
              screenSource: source, screenAlpha: 1, screenScale: 1, screenDim: 0,
              screenDark: 0, screenFlash: 0, screenOffsetX: 0,
              sweep: nil, sweepAlpha: 0, orb: nil, splash: nil, ambient: nil, arrival: 0)
    }

    /// 静息呼吸:一枚 2px 信号包沿当前源的链路走向屏幕,6 帧走完,其余时间完全静止。
    private static func ambientScene(_ source: MonitorInputSource, frame: Int) -> Scene {
        let progress: [CGFloat] = [0.04, 0.30, 0.55, 0.80, 0.96, 1.0]
        var scene = idleScene(source)
        scene.ambient = progress[frame]
        scene.arrival = frame == 5 ? 1 : 0
        scene.led = frame == 5 ? 1.35 : 1
        return scene
    }

    /// 12 帧分镜。数组下标即帧号,所有值都经过手调:
    /// 0 按压蓄力 → 1 起跳 → 2-4 迁移 → 5 落位/屏幕失步 → 6-7 新画面点亮 → 8-9 扫光 → 10-11 静息。
    private static func transitionScene(from: MonitorInputSource, to: MonitorInputSource,
                                        frame: Int, reverted: Bool) -> Scene {
        let oldChip: [CGFloat] = [1.00, 1.00, 0.80, 0.60, 0.42, 0.26, 0.12, 0, 0, 0, 0, 0]
        let newChip: [CGFloat] = [0, 0, 0, 0, 0, 0.70, 0.92, 1, 1, 1, 1, 1]
        let oldScale: [CGFloat] = [0.93, 0.95, 0.98, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        let newScale: [CGFloat] = [0.97, 0.97, 0.97, 0.97, 0.97, 1.06, 1.02, 1, 1, 1, 1, 1]
        let mix: [CGFloat] = [0, 0, 0, 0, 0, 0.35, 0.75, 1, 1, 1, 1, 1]
        let beamOld: [CGFloat] = [1, 1, 1, 0.95, 0.85, 0.45, 0, 0, 0, 0, 0, 0]
        let beamNew: [CGFloat] = [0, 0, 0, 0, 0, 0.45, 0.90, 1, 1, 1, 1, 1]
        let beamDraw: [CGFloat] = [0, 0, 0, 0, 0, 0.35, 0.90, 1, 1, 1, 1, 1]
        let screenAlpha: [CGFloat] = [0.90, 1.00, 1.00, 1.00, 0.72, 0, 0.55, 1, 1, 1, 1, 1]
        let screenScale: [CGFloat] = [1, 1, 1, 1, 1, 1, 1.05, 1, 1, 1, 1, 1]
        let screenOffset: [CGFloat] = [0, -1.0, -2.0, -2.0, -1.0, 0, 0, 0, 0, 0, 0, 0]
        let screenDark: [CGFloat] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        let screenFlash: [CGFloat] = [0, 0, 0, 0, 0, 0, 0.38, 0, 0, 0, 0, 0]
        let led: [CGFloat] = [1, 1, 1, 1, 1, 0.78, 0.94, 1, 1, 1, 1, 1]
        let error: [CGFloat] = [0, 0, 0, 0, 0, 0, 0.85, 0.15, 0.85, 0.30, 0, 0]

        // 迁移路径:起点/终点按「源」映射到固定芯片位(A=Mac,B=PC)
        let pathStart = chipRect(from).midTop
        let pathControl = CGPoint(x: 56, y: 77.5)
        let pathEnd = chipRect(to).midTop
        let progress: [CGFloat] = [0, 0, 0.16, 0.50, 0.84, 1.0, 1.0, 1, 1, 1, 1, 1]

        var orb: Orb?
        if frame <= 6 {
            var point = quadPoint(progress[frame], pathStart, pathControl, pathEnd)
            if frame == 5 {
                let tangent = quadTangent(1.0, pathStart, pathControl, pathEnd)
                point.x += tangent.x * 1.4
                point.y += tangent.y * 1.4
            }
            var trail: [CGPoint] = []
            if frame >= 2, frame <= 5 {
                for step in 1...3 {
                    let p = max(0, progress[frame] - CGFloat(step) * 0.075)
                    trail.append(quadPoint(p, pathStart, pathControl, pathEnd))
                }
            }
            let scales: [CGFloat] = [0.70, 1.25, 1.00, 1.00, 1.00, 1.18, 0.42, 0, 0, 0, 0, 0]
            let alphas: [CGFloat] = [0.85, 1.00, 1.00, 1.00, 1.00, 1.00, 0.35, 0, 0, 0, 0, 0]
            orb = Orb(point: point, scale: scales[frame], alpha: alphas[frame], trail: trail)
        }

        var splash: Splash?
        if frame == 5 {
            splash = Splash(point: pathEnd, radius: 3.5, alpha: 0.70)
        } else if frame == 6 {
            splash = Splash(point: pathEnd, radius: 8.0, alpha: 0.32)
        } else if frame == 7 {
            splash = Splash(point: pathEnd, radius: 11.0, alpha: 0.10)
        }

        let sweep: CGFloat? = frame == 8 ? 0.08 : frame == 9 ? 0.55 : frame == 10 ? 0.95 : nil
        let sweepAlpha: CGFloat = frame == 8 ? 0.10 : frame == 9 ? 0.20 : frame == 10 ? 0.12 : 0

        return Scene(
            from: from, to: to, mix: mix[frame],
            fromChip: oldChip[frame], toChip: newChip[frame],
            fromChipScale: oldScale[frame], toChipScale: newScale[frame],
            fromBeam: beamOld[frame], toBeam: beamNew[frame], toBeamDraw: beamDraw[frame],
            led: led[frame], errorBlink: reverted ? error[frame] : 0,
            screenSource: frame < 5 ? from : to,
            screenAlpha: screenAlpha[frame],
            screenScale: screenScale[frame],
            screenDim: frame == 4 ? 0.22 : 0,
            screenDark: screenDark[frame],
            screenFlash: screenFlash[frame],
            screenOffsetX: screenOffset[frame],
            sweep: sweep, sweepAlpha: sweepAlpha,
            orb: orb, splash: splash, ambient: nil, arrival: 0
        )
    }

    // MARK: 版式常量(112×112 设计坐标,左上原点)

    private static let monitorRect = CGRect(x: 24, y: 20, width: 64, height: 44)
    private static let screenRect = CGRect(x: 27.5, y: 23.5, width: 57, height: 37)
    private static let chipA = CGRect(x: 19, y: 84, width: 26, height: 16)
    private static let chipB = CGRect(x: 67, y: 84, width: 26, height: 16)
    private static let standNeck = CGRect(x: 54, y: 63.5, width: 4, height: 6)
    private static let standBase = CGRect(x: 45, y: 69, width: 22, height: 3)
    private static let ledCenter = CGPoint(x: 81.5, y: 58.5)
    private static let beamA = (start: CGPoint(x: 32, y: 84), control: CGPoint(x: 32.5, y: 74), end: CGPoint(x: 40, y: 64))
    private static let beamB = (start: CGPoint(x: 80, y: 84), control: CGPoint(x: 79.5, y: 74), end: CGPoint(x: 72, y: 64))

    private static func chipRect(_ source: MonitorInputSource) -> CGRect {
        source == .mac ? chipA : chipB
    }

    private static func beam(for source: MonitorInputSource) -> (start: CGPoint, control: CGPoint, end: CGPoint) {
        source == .mac ? beamA : beamB
    }

    /// 芯片亮度按「源」取:同一枚芯片可能同时是旧源(褪出)或新源(点亮),
    /// 取较大值即可覆盖两种方向,不需要在时间轴里区分 A/B。
    private static func chipActive(_ source: MonitorInputSource, scene: Scene) -> CGFloat {
        var value: CGFloat = 0
        if scene.from == source { value = max(value, scene.fromChip) }
        if scene.to == source { value = max(value, scene.toChip) }
        return value
    }

    private static func chipScale(_ source: MonitorInputSource, scene: Scene) -> CGFloat {
        if scene.to == source { return scene.toChipScale }
        if scene.from == source { return scene.fromChipScale }
        return 1
    }

    private static func beamAlpha(_ source: MonitorInputSource, scene: Scene) -> CGFloat {
        var value: CGFloat = 0
        if scene.from == source { value = max(value, scene.fromBeam) }
        if scene.to == source { value = max(value, scene.toBeam) }
        return value
    }

    private static func beamDraw(_ source: MonitorInputSource, scene: Scene) -> CGFloat {
        if scene.to == source { return scene.toBeamDraw }
        if scene.from == source { return 1 }
        return 0
    }

    // MARK: 绘制

    private static func draw(_ scene: Scene, in ctx: CGContext) {
        let macAccent = RGBA(MonitorInputSource.mac.accentHex)
        let pcAccent = RGBA(MonitorInputSource.pc.accentHex)
        let fromAccent = RGBA(scene.from.accentHex)
        let toAccent = RGBA(scene.to.accentHex)
        let accent = fromAccent.mixed(with: toAccent, scene.mix)

        // 底:近黑,而不是纯黑。留一点蓝灰,键面才像「屏幕」而不是「没画东西」。
        ctx.setFillColor(RGBA("#04060A").cg)
        ctx.fill(CGRect(x: 0, y: 0, width: designSize, height: designSize))

        // 显示器背后的源色氛围:状态的第一层暗示,10% 以下,不抢主体。
        drawRadialGlow(ctx, center: CGPoint(x: 56, y: 52), radius: 62,
                       color: accent.withAlpha(0.085), innerRadius: 0)

        // 链路在显示器后面。芯片是固定的(左 Mac / 右 PC),这里按「源」查询亮度,
        // 而不是把 from 永远画在左边——PC→Mac 时方向必须反过来。
        drawBeam(ctx, beam(for: .mac), color: macAccent,
                 alpha: beamAlpha(.mac, scene: scene), draw: beamDraw(.mac, scene: scene))
        drawBeam(ctx, beam(for: .pc), color: pcAccent,
                 alpha: beamAlpha(.pc, scene: scene), draw: beamDraw(.pc, scene: scene))

        drawMonitor(ctx, scene: scene, accent: accent)

        drawChip(ctx, rect: chipA, source: .mac,
                 active: chipActive(.mac, scene: scene), scale: chipScale(.mac, scene: scene),
                 accent: macAccent)
        drawChip(ctx, rect: chipB, source: .pc,
                 active: chipActive(.pc, scene: scene), scale: chipScale(.pc, scene: scene),
                 accent: pcAccent)

        if let ambient = scene.ambient {
            let beam = beam(for: scene.to)
            let p = CGFloat(ambient)
            let point = quadPoint(p, beam.start, beam.control, beam.end)
            let fade = sin(p * .pi)
            drawOrb(ctx, at: point, scale: 0.80, alpha: 0.85 * fade, color: toAccent)
        }
        if scene.arrival > 0 {
            let beam = beam(for: scene.to)
            ctx.setStrokeColor(toAccent.withAlpha(0.45 * scene.arrival))
            ctx.setLineWidth(0.9)
            ctx.strokeEllipse(in: CGRect(x: beam.end.x - 3.2, y: beam.end.y - 3.2, width: 6.4, height: 6.4))
        }

        if let orb = scene.orb {
            // 拖尾:从小到大的旧位置,营造速度感;不透明度逐级衰减
            for (index, point) in orb.trail.enumerated() {
                let k = CGFloat(index + 1)
                drawOrb(ctx, at: point,
                        scale: max(0.25, orb.scale * (0.62 - 0.12 * k)),
                        alpha: orb.alpha * (0.22 - 0.05 * k),
                        color: toAccent)
            }
            drawOrb(ctx, at: orb.point, scale: orb.scale, alpha: orb.alpha, color: toAccent)
        }

        if let splash = scene.splash {
            ctx.setStrokeColor(toAccent.withAlpha(splash.alpha))
            ctx.setLineWidth(1.0)
            ctx.strokeEllipse(in: CGRect(x: splash.point.x - splash.radius, y: splash.point.y - splash.radius,
                                         width: splash.radius * 2, height: splash.radius * 2))
        }
    }

    private static func drawMonitor(_ ctx: CGContext, scene: Scene, accent: RGBA) {
        // 底座先画,压住链路末端;再画显示器主体
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: RGBA("#000000").withAlpha(0.55))
        ctx.setFillColor(RGBA("#1A1F29").cg)
        ctx.addPath(roundedPath(standBase, 1.5))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.setFillColor(RGBA("#1E242F").cg)
        ctx.addPath(roundedPath(standNeck, 1.2))
        ctx.fillPath()

        // 机身:上亮下暗的金属/塑料渐变
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2.5), blur: 6, color: RGBA("#000000").withAlpha(0.55))
        ctx.addPath(roundedPath(monitorRect, 7))
        ctx.clip()
        fillLinear(ctx, rect: monitorRect, from: RGBA("#2A3140"), to: RGBA("#11151D"))
        ctx.restoreGState()

        // 机身高光边
        ctx.setStrokeColor(RGBA("#FFFFFF").withAlpha(0.085))
        ctx.setLineWidth(0.8)
        ctx.addPath(roundedPath(monitorRect, 7))
        ctx.strokePath()

        // 屏幕
        ctx.saveGState()
        ctx.addPath(roundedPath(screenRect, 4))
        ctx.clip()
        drawScreen(ctx, scene: scene, accent: accent)
        ctx.restoreGState()

        // 屏幕内圈:极细的黑色压边,让画面「沉」进边框
        ctx.setStrokeColor(RGBA("#000000").withAlpha(0.55))
        ctx.setLineWidth(1.1)
        ctx.addPath(roundedPath(screenRect, 4))
        ctx.strokePath()

        // 状态灯:真实显示器的电源/信号灯。颜色 = 当前源,切换时交叉淡化。
        let ledColor = scene.errorBlink > 0
            ? RGBA("#FF6B6B")
            : RGBA(scene.mix < 0.5 ? scene.from.accentHex : scene.to.accentHex)
        let ledAlpha = min(1, scene.led) * (scene.errorBlink > 0 ? (0.55 + 0.45 * scene.errorBlink) : 1)
        drawRadialGlow(ctx, center: ledCenter, radius: 5.5, color: ledColor.withAlpha(0.55 * ledAlpha), innerRadius: 0)
        ctx.setFillColor(ledColor.withAlpha(ledAlpha))
        ctx.fillEllipse(in: CGRect(x: ledCenter.x - 1.55, y: ledCenter.y - 1.55, width: 3.1, height: 3.1))
    }

    private static func drawScreen(_ ctx: CGContext, scene: Scene, accent: RGBA) {
        // 屏幕底色:始终有一点源色偏置,黑屏时也保留玻璃的冷调
        fillLinear(ctx, rect: screenRect, from: RGBA("#121A27"), to: RGBA("#070A10"))

        if scene.screenDark > 0.5 {
            // 输入源切换的真实瞬间:画面先失步(纯黑 + 一条残余扫描线)
            ctx.setFillColor(RGBA("#03050A").withAlpha(0.96))
            ctx.fill(screenRect)
            ctx.setFillColor(accent.withAlpha(0.10))
            ctx.fill(CGRect(x: screenRect.minX, y: screenRect.midY, width: screenRect.width, height: 0.8))
            return
        }

        let sourceAccent = RGBA(scene.screenSource.accentHex)
        let alpha = scene.screenAlpha

        ctx.saveGState()
        let center = CGPoint(x: screenRect.midX, y: screenRect.midY)
        ctx.translateBy(x: center.x + scene.screenOffsetX, y: center.y)
        ctx.scaleBy(x: scene.screenScale, y: scene.screenScale)
        ctx.translateBy(x: -center.x, y: -center.y)

        drawDesktop(ctx, source: scene.screenSource, accent: sourceAccent, alpha: alpha * (1 - scene.screenDim))

        if scene.screenFlash > 0 {
            drawRadialGlow(ctx, center: center, radius: 34,
                           color: sourceAccent.withAlpha(0.55 * scene.screenFlash), innerRadius: 0)
        }
        ctx.restoreGState()

        // 源色氛围:叠在画面之上,最薄的一层颜色身份
        ctx.setFillColor(sourceAccent.withAlpha(0.05 * alpha))
        ctx.fill(screenRect)

        // 点亮后的横向扫光:一帧起、一帧过、一帧收
        if let sweep = scene.sweep, scene.sweepAlpha > 0 {
            let x = screenRect.minX - 10 + (screenRect.width + 20) * sweep
            let colors = [RGBA("#FFFFFF").withAlpha(0), RGBA("#FFFFFF").withAlpha(scene.sweepAlpha),
                          RGBA("#FFFFFF").withAlpha(0)] as CFArray
            let locations: [CGFloat] = [0, 0.5, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: colors, locations: locations) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: x - 7, y: screenRect.minY),
                                       end: CGPoint(x: x + 7, y: screenRect.maxY),
                                       options: [])
            }
        }
    }

    /// 屏幕里的「桌面」:菜单栏 + 两扇窗 + 光标。细节在 112px 会糊,但轮廓能读出「有画面」。
    private static func drawDesktop(_ ctx: CGContext, source: MonitorInputSource, accent: RGBA, alpha: CGFloat) {
        let a = alpha
        // 菜单栏(Mac) / 底部任务栏(PC):一眼区分两套桌面语言
        if source == .mac {
            ctx.setFillColor(accent.withAlpha(0.22 * a))
            ctx.fill(CGRect(x: screenRect.minX, y: screenRect.minY, width: screenRect.width, height: 2.6))
        } else {
            ctx.setFillColor(accent.withAlpha(0.22 * a))
            ctx.fill(CGRect(x: screenRect.minX, y: screenRect.maxY - 3.0, width: screenRect.width, height: 3.0))
        }

        // 主窗口
        let window = CGRect(x: screenRect.minX + 7, y: screenRect.minY + 8.5, width: 25, height: 15)
        ctx.setFillColor(accent.withAlpha(0.10 * a))
        ctx.addPath(roundedPath(window, 2))
        ctx.fillPath()
        ctx.setStrokeColor(accent.withAlpha(0.38 * a))
        ctx.setLineWidth(0.8)
        ctx.addPath(roundedPath(window, 2))
        ctx.strokePath()
        // 标题栏三点
        for i in 0..<3 {
            ctx.setFillColor(RGBA("#FFFFFF").withAlpha(0.40 * a))
            ctx.fillEllipse(in: CGRect(x: window.minX + 2.2 + CGFloat(i) * 2.0,
                                       y: window.minY + 2.0, width: 1.1, height: 1.1))
        }
        // 两行内容
        for i in 0..<2 {
            ctx.setFillColor(accent.withAlpha(0.20 * a))
            ctx.fill(CGRect(x: window.minX + 2.4, y: window.minY + 6.4 + CGFloat(i) * 2.6,
                            width: i == 0 ? 15 : 11, height: 1.0))
        }

        // 副窗口
        let side = CGRect(x: screenRect.minX + 35, y: screenRect.minY + 16, width: 16, height: 11)
        ctx.setFillColor(RGBA("#FFFFFF").withAlpha(0.045 * a))
        ctx.addPath(roundedPath(side, 1.8))
        ctx.fillPath()
        ctx.setStrokeColor(accent.withAlpha(0.22 * a))
        ctx.setLineWidth(0.7)
        ctx.addPath(roundedPath(side, 1.8))
        ctx.strokePath()

        // 光标:三角箭头,画面里唯一的白色硬边
        let cursor = CGMutablePath()
        let cx = screenRect.minX + 30
        let cy = screenRect.minY + 22
        cursor.move(to: CGPoint(x: cx, y: cy))
        cursor.addLine(to: CGPoint(x: cx, y: cy + 5.2))
        cursor.addLine(to: CGPoint(x: cx + 3.6, y: cy + 3.4))
        cursor.closeSubpath()
        ctx.setFillColor(RGBA("#F4F8FF").withAlpha(0.78 * a))
        ctx.addPath(cursor)
        ctx.fillPath()
    }

    private static func drawChip(_ ctx: CGContext, rect: CGRect, source: MonitorInputSource,
                                 active: CGFloat, scale: CGFloat, accent: RGBA) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -center.x, y: -center.y)

        let base = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        ctx.setFillColor(RGBA("#141922").cg)
        ctx.addPath(roundedPath(base, 5))
        ctx.fillPath()

        if active > 0.01 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6.5, color: accent.withAlpha(0.55 * active))
            ctx.setFillColor(accent.withAlpha(0.15 * active))
            ctx.addPath(roundedPath(base, 5))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.setStrokeColor(active > 0.01
            ? accent.withAlpha(0.55 + 0.40 * active)
            : RGBA("#2B3341").withAlpha(0.9))
        ctx.setLineWidth(active > 0.01 ? 1.0 : 0.8)
        ctx.addPath(roundedPath(base, 5))
        ctx.strokePath()

        let glyphAlpha = 0.40 + 0.60 * active
        let glyphColor = active > 0.55
            ? RGBA("#FFFFFF").withAlpha(0.90)
            : RGBA("#93A0B5").withAlpha(glyphAlpha)
        drawGlyph(ctx, source: source, center: center, color: glyphColor)
        ctx.restoreGState()
    }

    private static func drawGlyph(_ ctx: CGContext, source: MonitorInputSource, center: CGPoint, color: CGColor) {
        // 单线字母标:在 26×16 的芯片里,任何设备剪影(笔记本/塔机)都会被读成手机或显示器。
        // M / P 是唯一在 112px 键面上零歧义的编码,也与用户口中的 Mac / PC 对齐。
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.7)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch source {
        case .mac:
            ctx.move(to: CGPoint(x: center.x - 3.9, y: center.y + 4.2))
            ctx.addLine(to: CGPoint(x: center.x - 3.9, y: center.y - 4.2))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y + 0.6))
            ctx.addLine(to: CGPoint(x: center.x + 3.9, y: center.y - 4.2))
            ctx.addLine(to: CGPoint(x: center.x + 3.9, y: center.y + 4.2))
            ctx.strokePath()
        case .pc:
            ctx.move(to: CGPoint(x: center.x - 3.1, y: center.y + 4.3))
            ctx.addLine(to: CGPoint(x: center.x - 3.1, y: center.y - 4.3))
            ctx.addLine(to: CGPoint(x: center.x + 0.6, y: center.y - 4.3))
            ctx.addQuadCurve(to: CGPoint(x: center.x + 3.7, y: center.y - 2.1),
                             control: CGPoint(x: center.x + 3.7, y: center.y - 4.3))
            ctx.addQuadCurve(to: CGPoint(x: center.x + 0.6, y: center.y + 0.1),
                             control: CGPoint(x: center.x + 3.7, y: center.y + 0.1))
            ctx.addLine(to: CGPoint(x: center.x - 3.1, y: center.y + 0.1))
            ctx.strokePath()
        }
    }

    private static func drawBeam(_ ctx: CGContext, _ beam: (start: CGPoint, control: CGPoint, end: CGPoint),
                                 color: RGBA, alpha: CGFloat, draw: CGFloat) {
        guard alpha > 0.01 else { return }
        let path = beamPath(beam, progress: draw)
        // 外层柔光 + 内层实线:一条有厚度的「信号」
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color.withAlpha(0.16 * alpha))
        ctx.setLineWidth(3.4)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setStrokeColor(color.withAlpha(0.82 * alpha))
        ctx.setLineWidth(1.25)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func beamPath(_ beam: (start: CGPoint, control: CGPoint, end: CGPoint),
                                 progress: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: beam.start)
        // 部分绘制:二次贝塞尔按参数截断(只需近似,视觉上足够)
        if progress >= 0.999 {
            path.addQuadCurve(to: beam.end, control: beam.control)
        } else {
            let endPoint = quadPoint(progress, beam.start, beam.control, beam.end)
            // 二次贝塞尔 0…p 子段的控制点 = A + p·(C − A),端点 = Q(p)
            let controlPoint = CGPoint(x: beam.start.x + (beam.control.x - beam.start.x) * progress,
                                       y: beam.start.y + (beam.control.y - beam.start.y) * progress)
            path.addQuadCurve(to: endPoint, control: controlPoint)
        }
        return path
    }

    private static func drawOrb(_ ctx: CGContext, at point: CGPoint, scale: CGFloat,
                                alpha: CGFloat, color: RGBA) {
        guard alpha > 0.01, scale > 0.01 else { return }
        let radius = 2.0 * scale
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 5, color: color.withAlpha(0.85 * alpha))
        ctx.setFillColor(RGBA("#F2F8FF").withAlpha(alpha))
        ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.restoreGState()
    }

    // MARK: 基础绘图

    private static func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func fillLinear(_ ctx: CGContext, rect: CGRect, from: RGBA, to: RGBA) {
        let locations: [CGFloat] = [0, 1]
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [from.cg, to.cg] as CFArray,
                                        locations: locations) else { return }
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.maxY),
                               options: [])
    }

    private static func drawRadialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                                       color: CGColor, innerRadius: CGFloat) {
        let locations: [CGFloat] = [0, 1]
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [color, color.copy(alpha: 0) ?? color] as CFArray,
                                        locations: locations) else { return }
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: innerRadius,
                               endCenter: center, endRadius: radius, options: [])
    }

    private static func quadPoint(_ t: CGFloat, _ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint {
        let mt = 1 - t
        return CGPoint(x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
                       y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y)
    }

    private static func quadTangent(_ t: CGFloat, _ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint {
        let x = 2 * (1 - t) * (c.x - a.x) + 2 * t * (b.x - c.x)
        let y = 2 * (1 - t) * (c.y - a.y) + 2 * t * (b.y - c.y)
        let length = max(0.0001, sqrt(x * x + y * y))
        return CGPoint(x: x / length, y: y / length)
    }

    private static func rotated180(_ image: CGImage) -> CGImage? {
        let side = image.width
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        // 绕原点旋转必须先平移到对角,否则内容落进负坐标只剩 1/4(2026-10 实测)
        ctx.translateBy(x: CGFloat(side), y: CGFloat(side))
        ctx.rotate(by: .pi)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}

// MARK: - 颜色

/// 颜色组件 + 混色运算。hex 解析不在本文件(统一走 HexCGColor,与 stats/热力图同源);
/// 本文件仍不依赖 AppKit / StreamDockKit,便于单文件编译成预览工具。
private struct RGBA {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    init(_ hex: String, _ alpha: CGFloat = 1) {
        // 解析统一走 HexCGColor(与 stats 瓷贴、热力图同一份);取不到时落黑,与旧实现一致
        let components = HexCGColor.parse(hex)?.components ?? []
        r = components.count >= 3 ? components[0] : 0
        g = components.count >= 3 ? components[1] : 0
        b = components.count >= 3 ? components[2] : 0
        a = alpha
    }

    var cg: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func withAlpha(_ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: max(0, min(1, alpha)))
    }

    func mixed(with other: RGBA, _ t: CGFloat) -> RGBA {
        let k = max(0, min(1, t))
        return RGBA(r: r + (other.r - r) * k, g: g + (other.g - g) * k,
                    b: b + (other.b - b) * k, a: a + (other.a - a) * k)
    }

    private init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

// MARK: - 版式辅助

private extension CGRect {
    var midTop: CGPoint { CGPoint(x: midX, y: minY) }
}
