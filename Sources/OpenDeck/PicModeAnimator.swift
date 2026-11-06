import CoreGraphics
import Foundation

/// 图像模式 toggle 键的节拍器(§6.39):显示当前图像模式(玩家1/阅读),
/// 按压切换到另一档并播扫动过渡;外部变化(其它路径切档)由 1.5s 轮询对账跟随。
///
/// 事实源 = ~/.cache/lg_pic_mode(ActionRunner 在 DDC 成功后写);
/// 本动画器是消费者,不做乐观假设(§3 外部事实对账哲学)。
@MainActor
final class PicModeAnimator {
    var onFrame: ((Int, CGImage) -> Void)?
    var onLog: ((String) -> Void)?

    private var activeIndex: Int?
    private var pollTimer: Timer?
    /// 过渡帧播放器(与 TileFXPlayer 同族;独立实例避免与睡眠锁会话互扰)
    private let fx = TileFXPlayer()

    /// 上次渲染的档(变化检测 + 轮询对账比较)
    private var lastMode: PicModeTileRenderer.Mode = .unknown
    /// 在飞标志:过渡播放期间轮询到同档变化不重启动画
    private var transitioning = false

    init() {
        fx.onFrame = { [weak self] index, image in
            self?.onFrame?(index, image)
        }
    }

    /// 挂载:立即渲染当前档 + 起 1.5s 轮询(applyKey 对账点调用;幂等)
    func attach(index: Int) {
        let wasActive = activeIndex != nil
        activeIndex = index
        let mode = PicModeTileRenderer.Mode(stateFile: PicModeTileRenderer.currentStateFile())
        lastMode = mode
        if let image = PicModeTileRenderer.image(mode: mode), !wasActive {
            onFrame?(index, image)
        }
        startPolling()
    }

    func detach(ifIndex index: Int) {
        guard activeIndex == index else { return }
        activeIndex = nil
        fx.stop(ifIndex: index)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 按下沿:切换到另一档并播扫动过渡。真实动作(preserves picGame1/picReader)
    /// 由 AppModel 照常执行——动作落盘的档与本动画器推导的目标一致(都读同一状态文件),
    /// 不一致时轮询对账会纠正(§3 哲学)。
    func handlePress(index: Int) {
        guard activeIndex == index else { return }
        let current = PicModeTileRenderer.Mode(stateFile: PicModeTileRenderer.currentStateFile())
        let target = current.flipped
        guard current != .unknown else {
            // 状态未知:不播过渡(首按直接落 game),轮询/ActionRunner 写盘后跟随
            onLog?("图像模式:状态未知,按压直接落 玩家1")
            return
        }
        onLog?("图像模式:\(current.label) → \(target.label)(按压切换)")
        guard let frames = PicModeTileRenderer.transitionFrames(from: current, to: target),
              let final = PicModeTileRenderer.image(mode: target)
        else { return }
        lastMode = target
        transitioning = true
        fx.play(index: index, frames: frames, final: final)
        // 过渡播放完再放行轮询对账(0.5s 足够 6 帧@15fps)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.transitioning = false
        }
    }

    // MARK: 轮询对账

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollOnce() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollOnce() {
        guard activeIndex != nil, !transitioning else { return }
        let mode = PicModeTileRenderer.Mode(stateFile: PicModeTileRenderer.currentStateFile())
        guard mode != lastMode else { return }
        lastMode = mode
        onLog?("图像模式:外部变化 → \(mode.label),键面跟随")
        if let index = activeIndex, let image = PicModeTileRenderer.image(mode: mode) {
            onFrame?(index, image)
        }
    }
}
