import CoreGraphics
import Foundation

/// 瓷贴过渡帧播放器(§6.33):统计弧线扫摆、睡眠锁扣开合共用。
/// 与 PressPulseAnimator(按压驱动)不同,这里播**预构建的帧序列**——状态变化时
/// 调用方一次性生成 6–8 帧,播放器逐帧吐出,收尾回落到调用方给定的静息帧。
/// 多键:按 keyIndex 独立会话;换页/改键由 applyKey 顶部的 stop 统一清场。
@MainActor
final class TileFXPlayer {
    var onFrame: ((Int, CGImage) -> Void)?

    private struct Session {
        var frames: [CGImage]
        var final: CGImage
        var index: Int
        var timer: Timer
    }

    private var sessions: [Int: Session] = [:]

    /// 播一段帧序列(已含首帧);结束吐 final。同键重播 = 重置进度
    func play(index: Int, frames: [CGImage], final: CGImage, fps: Double = 15) {
        stop(ifIndex: index)
        guard !frames.isEmpty else { return }
        let timer = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(index) }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        sessions[index] = Session(frames: frames, final: final, index: index, timer: timer)
        emit(index) // 首帧立即
    }

    func stop(ifIndex index: Int) {
        guard let session = sessions.removeValue(forKey: index) else { return }
        session.timer.invalidate()
    }

    func stopAll() {
        for index in Array(sessions.keys) { stop(ifIndex: index) }
    }

    private func tick(_ index: Int) {
        guard var session = sessions[index] else { return }
        session.frames.removeFirst()
        if session.frames.isEmpty {
            session.timer.invalidate()
            sessions.removeValue(forKey: index)
            onFrame?(session.index, session.final)
            return
        }
        sessions[index] = session
        emit(index)
    }

    private func emit(_ index: Int) {
        guard let session = sessions[index], let frame = session.frames.first else { return }
        onFrame?(index, frame)
    }
}
