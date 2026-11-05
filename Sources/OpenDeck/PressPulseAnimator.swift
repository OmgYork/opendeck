import CoreGraphics
import Foundation

/// 通用按压脉冲键面(§6.32):任何普通键开启后,按下沿闪亮 + 微放大一小段再回静息帧。
/// 与 MonitorInputAnimator(单实例/整帧接管)不同,脉冲是**多键**的——每颗键独立一段
/// 脉冲会话,静息帧就是常规渲染产物,脉冲只是按压沿的短暂叠加,不接管键面。
///
/// 帧生成是纯函数(`pulseImage`),设备帧/UI 镜像同源走 onFrame。
@MainActor
final class PressPulseAnimator {
    /// 每键帧回调(AppModel 负责写设备 + UI 镜像)
    var onFrame: ((Int, CGImage) -> Void)?

    /// 脉冲帧数与节拍:8 帧 @ 12fps ≈ 0.66s,按压反馈的黄金手感区间
    static let frameCount = 8
    static let frameInterval: TimeInterval = 1.0 / 12.0

    private struct Session {
        let base: CGImage
        let size: Int
        var frame: Int
        var timer: Timer
    }

    private var sessions: [Int: Session] = [:]

    /// 挂载:静息帧(常规渲染产物)作为脉冲基帧。编辑保存/换页后由 applyKey 重新挂载
    func attach(index: Int, base: CGImage) {
        detach(ifIndex: index) // 重挂 = 基帧更新
        sessions[index] = Session(base: base, size: base.width, frame: 0,
                                  timer: Timer()) // timer 占位,handlePress 时重建
    }

    func detach(ifIndex index: Int) {
        guard let session = sessions.removeValue(forKey: index) else { return }
        session.timer.invalidate()
    }

    func detachAll() {
        for index in Array(sessions.keys) { detach(ifIndex: index) }
    }

    func isAttached(index: Int) -> Bool { sessions[index] != nil }

    /// 按下沿:有挂载且不在脉冲中才起一段(连按只重置进度,不叠 Timer)
    func handlePress(index: Int) {
        guard var session = sessions[index], session.timer.isValid == false else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(index) }
        }
        RunLoop.main.add(timer, forMode: .common)
        timer.tolerance = 0.02
        session.timer = timer
        session.frame = 0
        sessions[index] = session
        emit(index, progress: 0, base: session.base) // 首帧立即,不等一拍
    }

    private func advance(_ index: Int) {
        guard var session = sessions[index] else { return }
        session.frame += 1
        if session.frame >= Self.frameCount {
            session.timer.invalidate()
            sessions[index] = session
            onFrame?(index, session.base) // 收尾回静息帧
            return
        }
        sessions[index] = session
        emit(index, progress: Double(session.frame) / Double(Self.frameCount), base: session.base)
    }

    private func emit(_ index: Int, progress: Double, base: CGImage) {
        guard let image = Self.pulseImage(base: base, progress: progress) else { return }
        onFrame?(index, image)
    }

    // MARK: 帧生成(纯函数)

    /// 脉冲帧:白光叠加亮度闪(alpha = 0.45·(1-p)^1.5,快起慢收)+ 轻微放大
    /// (zoom = 1 + 0.05·sin(pπ),鼓包一次)。progress = 0 是最亮帧,≥1 或异常一律回原图。
    /// 静息期零成本:不新建 CGContext 就不出帧,只有按压的那 0.66s 在动
    nonisolated static func pulseImage(base: CGImage, progress: Double) -> CGImage? {
        guard progress > 0, progress < 1, base.width > 0 else { return base }
        let side = base.width
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return base }
        let flashAlpha = 0.45 * pow(1 - progress, 1.5)
        let zoom = 1 + 0.05 * sin(progress * .pi)
        let drawSide = CGFloat(side) * zoom
        let inset = (CGFloat(side) - drawSide) / 2
        ctx.interpolationQuality = .medium
        ctx.draw(base, in: CGRect(x: inset, y: inset, width: drawSide, height: drawSide))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: flashAlpha))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}
