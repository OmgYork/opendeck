import AppKit
import CoreGraphics
import Foundation

/// 显示器输入源动效的状态机与节拍器。
///
/// 三方事实必须收敛:设备上显示的键面、`~/.cache/lg_input` 里的真实输入源、
/// 以及用户刚按下时「预期会切到哪」的乐观目标。策略:
/// 1. 按下立刻播 12 帧迁移(不等外部脚本),给出手感;
/// 2. 过渡期间不响应外部轮询,避免脚本还没来得及写文件就被判失败;
/// 3. 动画结束后轮询状态文件:对上 = 确认;超时没变 = 播一次回退动画(红色闪灯)。
@MainActor
final class MonitorInputAnimator {
    static let stateFilePath = MonitorInputIconRenderer.stateFilePath

    /// 每帧上屏回调(AppModel 负责写设备 + UI 镜像)
    var onFrame: ((CGImage) -> Void)?
    /// 诊断日志
    var onLog: ((String) -> Void)?

    /// 当前挂载的键位索引(同一时刻只服务一颗键)
    private(set) var activeIndex: Int?
    /// 最近一次确认的输入源
    private(set) var source: MonitorInputSource

    private var size = 112
    private var transition: Transition?
    private var pending: PendingSwitch?
    private var frameTimer: Timer?
    private var pollTimer: Timer?
    private var ambientTimer: Timer?
    private var ambientTicker: Timer?
    private var ambientFrame: Int?
    private var lastFrame: MonitorIconFrame?
    private var previewCache: (source: MonitorInputSource, size: Int, image: CGImage)?

    private struct Transition {
        let from: MonitorInputSource
        let to: MonitorInputSource
        let reverted: Bool
        var frame: Int
    }

    private struct PendingSwitch {
        let target: MonitorInputSource
        let deadline: Date
    }

    init() {
        source = Self.readState() ?? .mac
    }

    // MARK: - 挂载/卸载

    /// 键位出现在当前页时调用。幂等:同键同尺寸重复调用不会重启动画。
    func attach(index: Int, size: Int) {
        if activeIndex == index, self.size == size { return }
        activeIndex = index
        self.size = size
        transition = nil
        stopFrameTimer()
        lastFrame = nil
        // 换页回来时以磁盘为准,避免显示离开页面之前的旧状态
        if pending == nil, let disk = Self.readState() {
            source = disk
        }
        renderIdle(force: true)
        startPolling()
        scheduleAmbient()
    }

    /// 该索引离开当前页或不再是动效键时调用
    func detach(ifIndex index: Int) {
        guard activeIndex == index else { return }
        activeIndex = nil
        transition = nil
        pending = nil
        lastFrame = nil
        ambientFrame = nil
        stopFrameTimer()
        stopAmbientTicker()
        ambientTimer?.invalidate()
        ambientTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - 按键

    /// 按下沿调用:立即可视反馈 + 乐观目标。真实动作由 AppModel 照常执行。
    func handlePress() {
        guard activeIndex != nil else { return }
        let displayed = displayedSource
        // 以磁盘为准推导目标(脚本按文件状态取反),避免图标与真实输入错一拍
        let disk = Self.readState() ?? source
        let target = disk.opposite
        pending = PendingSwitch(target: target, deadline: Date().addingTimeInterval(3.0))
        onLog?("显示器输入:按键 → \(target.label)(当前 \(displayed.label))")

        guard transition == nil else { return } // 迁移中:让当前动画跑完,随后交给对账
        if target == displayed {
            source = target
            renderIdle(force: true)
            return
        }
        startTransition(from: displayed, to: target, reverted: false)
    }

    /// 编辑器实时预览用:当前源的静息帧(已预旋转,与设备帧同源)
    func previewImage(size: Int) -> CGImage? {
        if let cache = previewCache, cache.source == source, cache.size == size {
            return cache.image
        }
        guard let image = MonitorInputIconRenderer.image(
            size: size, frame: .idle(source), prerotated: true
        ) else { return nil }
        previewCache = (source, size, image)
        return image
    }

    // MARK: - 时间轴

    private var displayedSource: MonitorInputSource { transition?.to ?? source }

    private func startTransition(from: MonitorInputSource, to: MonitorInputSource, reverted: Bool) {
        ambientTimer?.invalidate()
        ambientTimer = nil
        stopAmbientTicker()
        ambientFrame = nil
        transition = Transition(from: from, to: to, reverted: reverted, frame: 0)
        render(.transition(from: from, to: to, frame: 0, reverted: reverted), force: true)
        startFrameTimer()
    }

    private func advanceTransition() {
        guard var current = transition else {
            stopFrameTimer()
            return
        }
        current.frame += 1
        if current.frame >= MonitorIconTiming.transitionFrameCount {
            transition = nil
            stopFrameTimer()
            source = current.to
            lastFrame = nil
            renderIdle(force: true)
            // 脚本已写入目标态就当场销账;否则留给轮询在 deadline 处判定
            if let pending, Self.readState() == pending.target {
                self.pending = nil
            }
            scheduleAmbient()
            return
        }
        transition = current
        render(.transition(from: current.from, to: current.to,
                           frame: current.frame, reverted: current.reverted))
    }

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: MonitorIconTiming.transitionFrameDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceTransition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    // MARK: - 状态对账

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollState() {
        guard activeIndex != nil, let disk = Self.readState() else { return }

        if let pending {
            if disk == pending.target {
                self.pending = nil
                if transition == nil {
                    source = disk
                    renderIdle()
                }
                return
            }
            if Date() >= pending.deadline {
                self.pending = nil
                onLog?("显示器输入:切换未生效,回退到 \(disk.label)")
                startTransition(from: displayedSource, to: disk, reverted: true)
            }
            return
        }

        // 外部切换(显示器摇杆/其它触发的快捷指令):跟着真实状态走
        if transition == nil, disk != source {
            onLog?("显示器输入:检测到外部切换 → \(disk.label)")
            startTransition(from: source, to: disk, reverted: false)
        }
    }

    // MARK: - 静息呼吸

    private func scheduleAmbient() {
        ambientTimer?.invalidate()
        ambientTimer = nil
        guard activeIndex != nil, transition == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: MonitorIconTiming.ambientPeriod, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.playAmbient() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ambientTimer = timer
    }

    private func playAmbient() {
        guard activeIndex != nil, transition == nil, ambientFrame == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        ambientFrame = 0
        render(.ambient(source, frame: 0), force: true)
        startAmbientTicker()
    }

    private func startAmbientTicker() {
        stopAmbientTicker()
        let timer = Timer(timeInterval: MonitorIconTiming.ambientFrameDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceAmbient() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ambientTicker = timer
    }

    private func advanceAmbient() {
        guard let current = ambientFrame else {
            stopAmbientTicker()
            return
        }
        let next = current + 1
        if next >= MonitorIconTiming.ambientFrameCount {
            ambientFrame = nil
            stopAmbientTicker()
            renderIdle(force: true)
            scheduleAmbient()
            return
        }
        ambientFrame = next
        render(.ambient(source, frame: next))
    }

    private func stopAmbientTicker() {
        ambientTicker?.invalidate()
        ambientTicker = nil
    }

    // MARK: - 渲染

    private func renderIdle(force: Bool = false) {
        render(.idle(source), force: force)
    }

    private func render(_ frame: MonitorIconFrame, force: Bool = false) {
        guard activeIndex != nil else { return }
        if !force, frame == lastFrame { return }
        guard let image = MonitorInputIconRenderer.image(size: size, frame: frame) else { return }
        lastFrame = frame
        onFrame?(image)
    }

    private static func readState() -> MonitorInputSource? {
        guard let text = try? String(contentsOfFile: stateFilePath, encoding: .utf8) else { return nil }
        return MonitorInputSource.parse(text)
    }
}
