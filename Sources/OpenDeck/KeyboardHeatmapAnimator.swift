import AppKit
import CoreGraphics
import Foundation
import os

/// 键盘热力图键的状态机与节拍器。
///
/// 三方事实：库里的「今日合计」、App 自己广播的状态、以及用户按下时的一次请求。
/// 策略：
/// 1. 每 10 秒读一次库与状态，只在值/状态变化时上屏（静息零 USB 流量）；
/// 2. 转场按 12fps 整帧播放（与 MonitorInputAnimator 同一节拍）；
/// 3. 呼吸点 1 秒一帧（8 帧一循环），代价 60 次/分钟，远低于显示器动效键；
/// 4. 中断态按下 = 把「重试统计」发回 App；8 秒内没恢复就播失败抖动并留在中断态。
@MainActor
final class KeyboardHeatmapAnimator {
    /// 每帧上屏回调（AppModel 负责写设备 + UI 镜像）
    var onFrame: ((CGImage) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var activeIndex: Int?
    private var size = 112

    private var phase: HeatmapPhase = .off
    private var probePhase: HeatmapPhase = .off
    private var today: Int64 = 0
    private var shownValue: Int64 = 0

    private var transition: Transition?
    private var breatheStep = 0
    private var retryDeadline: Date?

    private var frameTimer: Timer?
    private var pollTimer: Timer?
    private var breatheTimer: Timer?
    private var retryTimer: Timer?
    private var bridgeObserver: NSObjectProtocol?

    private struct Transition {
        enum Kind { case tick, enterAttention, recover, fail, press, midnight }
        var kind: Kind
        var frame: Int
        var total: Int
        var fromValue: Int64
        var toValue: Int64
    }

    // MARK: 挂载 / 卸载

    func attach(index: Int, size: Int) {
        if activeIndex == index, self.size == size { return }
        activeIndex = index
        self.size = size
        transition = nil
        refresh(force: true)
        startPolling()
        startBreathing()
        observeBridge()
        if transition == nil { renderStatic() }
        onLog?("热力图键：挂载 index=\(index) 相位=\(phase.rawValue) 今日=\(shownValue)")
    }

    func detach(ifIndex index: Int) {
        guard activeIndex == index else { return }
        activeIndex = nil
        transition = nil
        stopFrameTimer()
        stopRetryTimer()
        pollTimer?.invalidate(); pollTimer = nil
        breatheTimer?.invalidate(); breatheTimer = nil
        if let bridgeObserver {
            DistributedNotificationCenter.default().removeObserver(bridgeObserver)
            self.bridgeObserver = nil
        }
    }

    // MARK: 按下

    func handlePress() {
        guard activeIndex != nil else { return }
        switch phase {
        case .normal:
            play(.press)
            if bridgeReady {
                onLog?("热力图键：打开 dashboard")
                HeatmapProbe.send(command: "showDashboard")
            } else {
                onLog?("热力图键：桥接未安装，只能唤起应用（面板需手动点菜单栏）")
                HeatmapProbe.openApp()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.finishTransitionIfNeeded()
            }
        case .attention:
            if bridgeReady {
                beginRetry()
            } else {
                restartAppFallback()
            }
        case .off, .unreadable:
            onLog?("热力图键：应用未运行，尝试启动")
            play(.press)
            HeatmapProbe.openApp()
        case .retrying:
            onLog?("热力图键：重试进行中，忽略连点")
        }
    }

    /// 桥接是否在线（状态文件新鲜）。没有它就只能退回进程级恢复。
    private var bridgeReady: Bool {
        guard let state = HeatmapProbe.bridgeState(), let at = state.updatedAt else { return false }
        return Date().timeIntervalSince(at) < 300
    }

    /// 无桥接时的兜底：重启 KeyAnalyze。它是官方认可的恢复路径（`.attention` 只有用户重试或重启能退出），
    /// 代价是最多丢掉一个 flush 周期（15 秒）的未落盘计数。
    private func restartAppFallback() {
        onLog?("热力图键：桥接未安装，改为重启 KeyAnalyze 恢复")
        play(.press)
        phase = .retrying
        retryDeadline = Date().addingTimeInterval(12)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: HeatmapStore.bundleID) {
            app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            HeatmapProbe.openApp()
            self.startFrameTimer()
            self.startRetryTimer()
            self.renderStatic()
        }
    }

    private func beginRetry() {
        onLog?("热力图键：触发「重试统计」")
        phase = .retrying
        retryDeadline = Date().addingTimeInterval(8)
        HeatmapProbe.send(command: "retry")
        startFrameTimer()
        startRetryTimer()
        renderStatic()
    }

    private func startRetryTimer() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateRetry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func evaluateRetry() {
        guard phase == .retrying else { stopRetryTimer(); return }
        refresh(force: true)
        if probePhase == .normal {
            onLog?("热力图键：已恢复统计")
            retryDeadline = nil
            stopRetryTimer()
            play(.recover)
            return
        }
        if let deadline = retryDeadline, Date() > deadline {
            onLog?("热力图键：重试未成功，保留中断态")
            retryDeadline = nil
            stopRetryTimer()
            play(.fail)
        }
    }

    // MARK: 采样

    private func refresh(force: Bool = false) {
        guard activeIndex != nil else { return }
        let reading = HeatmapStore.readToday()
        let truth = HeatmapProbe.phase(reading: reading)

        var value: Int64 = shownValue
        switch reading {
        case let .success(data): value = data.today
        case .failure: break
        }
        if let bridge = HeatmapProbe.bridgeState(), let bridgeToday = bridge.today, bridgeToday > value {
            value = bridgeToday
        }

        let previousTruth = probePhase
        probePhase = truth
        if phase == .retrying, truth != .normal { phase = .attention } else { phase = truth }

        // 数值变化：正常增长走滚动；跨零点走翻页
        if value != shownValue {
            let dayChanged = value < shownValue && shownValue > 0 && Calendar.current.isDate(Date(), inSameDayAs: Date())
            play(dayChanged && value == 0 ? .midnight : .tick, from: shownValue, to: value)
            shownValue = value
        } else if force {
            renderStatic()
        }

        // 状态变化
        if truth == .attention, previousTruth == .normal || previousTruth == .off {
            play(.enterAttention)
        } else if truth == .normal, previousTruth == .attention, transition?.kind != .recover {
            play(.recover)
        }
    }

    private func observeBridge() {
        guard bridgeObserver == nil else { return }
        bridgeObserver = DistributedNotificationCenter.default().addObserver(
            forName: HeatmapProbe.stateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func startBreathing() {
        guard breatheTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.transition == nil, self.phase == .normal || self.phase == .attention else { return }
                self.breatheStep = (self.breatheStep + 1) % 8
                self.renderStatic()
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        breatheTimer = timer
    }

    // MARK: 转场

    private func play(_ kind: Transition.Kind, from: Int64? = nil, to: Int64? = nil) {
        let total: Int
        switch kind {
        case .tick: total = 4
        case .enterAttention: total = 3
        case .recover: total = 5
        case .fail: total = 4
        case .press: total = 2
        case .midnight: total = 4
        }
        transition = Transition(kind: kind, frame: 0,
                                total: total,
                                fromValue: from ?? shownValue,
                                toValue: to ?? shownValue)
        startFrameTimer()
        render()
    }

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func advanceFrame() {
        guard var current = transition else {
            if phase != .retrying { stopFrameTimer() }
            return
        }
        current.frame += 1
        if current.frame >= current.total {
            transition = nil
            if phase != .retrying { stopFrameTimer() }
            renderStatic()
            return
        }
        transition = current
        render()
    }

    private func finishTransitionIfNeeded() {
        transition = nil
        if phase != .retrying { stopFrameTimer() }
        renderStatic()
    }

    // MARK: 渲染

    private func renderStatic() {
        let breathe = 0.5 - 0.5 * cos(Double(breatheStep) / 8.0 * 2 * .pi)
        var scene = HeatmapScene(numberFrom: displayText, numberTo: displayText)
        scene.dotBrightness = CGFloat(breathe)
        switch phase {
        case .normal:
            scene.alpha = 1; scene.rail = .idle; scene.badgeAlpha = 0.45
        case .attention:
            scene.alpha = 0.45; scene.rail = .warn; scene.railHeight = 6
            scene.hatch = 1; scene.badgeAlpha = 1; scene.warnBadge = true
        case .retrying:
            scene.alpha = 0.25; scene.rail = .retry; scene.railHeight = 6
            scene.badgeAlpha = 1; scene.warnBadge = true
            scene.sweep = CGFloat(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0))
        case .off, .unreadable:
            scene = HeatmapScene(numberFrom: "—", numberTo: "—")
            scene.rail = .off; scene.badgeAlpha = 0.28
        }
        emit(scene)
    }

    private var displayText: String {
        switch phase {
        case .off, .unreadable: return "—"
        default: return HeatmapFormat.count(shownValue)
        }
    }

    private func render() {
        guard let t = transition else { renderStatic(); return }
        let p = CGFloat(t.frame) / CGFloat(max(1, t.total - 1))
        let eased = easeOut(p)
        var scene = HeatmapScene(numberFrom: HeatmapFormat.count(t.fromValue),
                                 numberTo: HeatmapFormat.count(t.toValue))

        switch t.kind {
        case .tick:
            scene.roll = eased
            scene.roll = eased
            scene.alpha = 1
            scene.rail = .idle
            scene.flash = max(0, 1 - CGFloat(t.frame) / 2.4)
        case .enterAttention:
            scene.alpha = 1 - 0.55 * p
            scene.rail = .warn
            scene.railHeight = 2 + 4 * p
            scene.hatch = p
            scene.badgeAlpha = 0.45 + 0.55 * p
            scene.warnBadge = true
            scene.numberFrom = displayText
            scene.numberTo = displayText
        case .recover:
            scene.alpha = 0.45 + 0.55 * p
            scene.rail = t.frame < 3 ? .warn : .idle
            scene.railHeight = 6 - 4 * p
            scene.hatch = 1 - p
            scene.badgeAlpha = 1 - 0.55 * p
            scene.warnBadge = t.frame < 2
            scene.flash = t.frame < 2 ? 1 - p : 0
            scene.roll = eased
        case .fail:
            scene.alpha = 0.45
            scene.rail = .warn
            scene.railHeight = 6
            scene.hatch = 1
            scene.badgeAlpha = 1
            scene.warnBadge = true
            scene.shake = [0, 2, -2, 1][min(3, t.frame)]
            scene.numberFrom = displayText
            scene.numberTo = displayText
        case .press:
            scene.dim = 1 - p
            scene.sheen = 1 - p
            scene.rail = phase == .normal ? .idle : (phase == .attention ? .warn : .off)
        case .midnight:
            scene.roll = eased
            scene.alpha = 1
            scene.rail = .idle
        }
        emit(scene)
    }

    private func emit(_ scene: HeatmapScene) {
        guard let image = HeatmapRenderer.image(scene: scene, side: size) else { return }
        onFrame?(image)
    }

    /// 编辑器预览：当前相位下的静息帧
    func previewImage(size: Int) -> CGImage? {
        var scene = HeatmapScene(numberFrom: displayText, numberTo: displayText)
        switch phase {
        case .normal: scene.rail = .idle; scene.dotBrightness = 0.6
        case .attention: scene.alpha = 0.45; scene.rail = .warn; scene.railHeight = 6; scene.warnBadge = true; scene.badgeAlpha = 1
        case .retrying: scene.alpha = 0.25; scene.rail = .retry; scene.railHeight = 6; scene.warnBadge = true; scene.badgeAlpha = 1
        case .off, .unreadable: scene = HeatmapScene(numberFrom: "—", numberTo: "—"); scene.rail = .off
        }
        return HeatmapRenderer.image(scene: scene, side: size)
    }

    private func easeOut(_ p: CGFloat) -> CGFloat {
        let c = min(1, max(0, p))
        return 1 - pow(1 - c, 3)
    }
}
