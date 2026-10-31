import AppKit
import CoreGraphics
import Foundation
import os

/// 键盘热力图键的状态机与节拍器（灯带版）。
///
/// 三方事实：库里的「今日合计」、App 自己广播的状态、以及用户按下时的一次请求。
/// 灯带语义（L1–L5）：
///   L1 白灯常亮 = 记录中（数值变化只由主内容滚动表达）
///   L2 红灯常亮 = 中断
///   L3 红灯闪烁 = 重试中（6 亮 / 6 灭，12fps）
///   L4 绿灯闪两下 = 恢复成功（3 亮 / 3 灭 ×2，之后回 L1）
///   L5 灰灯 = 未运行/不可读（主内容显示 X）
@MainActor
final class KeyboardHeatmapAnimator {
    var onFrame: ((CGImage) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var activeIndex: Int?
    private var size = 112

    enum Phase: String {
        case normal, attention, retrying, recovered, off, unreadable
    }

    private var phase: Phase = .off
    private var probePhase: Phase = .off
    private var shownValue: Int64 = 0

    private var transition: Transition?
    private var blinkTicks = 0
    private var retryDeadline: Date?

    private var frameTimer: Timer?
    private var pollTimer: Timer?
    private var retryTimer: Timer?
    private var bridgeObserver: NSObjectProtocol?
    private var activationObservers: [NSObjectProtocol] = []

    private struct Transition {
        enum Kind { case tick, enterAttention, fail, press, midnight }
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
        blinkTicks = 0
        refresh(force: true)
        startPolling()
        observeBridge()
        observeSystemActivation()
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
        if let bridgeObserver {
            DistributedNotificationCenter.default().removeObserver(bridgeObserver)
            self.bridgeObserver = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        activationObservers.forEach { center.removeObserver($0) }
        activationObservers.removeAll()
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
        case .retrying, .recovered:
            onLog?("热力图键：重试/恢复进行中，忽略连点")
        case .off, .unreadable:
            onLog?("热力图键：应用未运行，尝试启动")
            play(.press)
            HeatmapProbe.openApp()
        }
    }

    private var bridgeReady: Bool {
        guard let state = HeatmapProbe.bridgeState(), let at = state.updatedAt else { return false }
        return Date().timeIntervalSince(at) < 300
    }

    private func restartAppFallback() {
        onLog?("热力图键：桥接未安装，改为重启 KeyAnalyze 恢复")
        play(.press)
        beginBlinking(.retrying)
        retryDeadline = Date().addingTimeInterval(12)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: HeatmapStore.bundleID) {
            app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            HeatmapProbe.openApp()
            self.startRetryTimer()
            self.renderStatic()
        }
    }

    private func beginRetry() {
        onLog?("热力图键：触发「重试统计」")
        retryDeadline = Date().addingTimeInterval(8)
        HeatmapProbe.send(command: "retry")
        beginBlinking(.retrying)
        startRetryTimer()
    }

    private func beginBlinking(_ target: Phase) {
        phase = target
        blinkTicks = 0
        startFrameTimer()
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
            beginBlinking(.recovered)          // L4：绿灯闪两下
            return
        }
        if let deadline = retryDeadline, Date() > deadline {
            onLog?("热力图键：重试未成功，保留中断态")
            retryDeadline = nil
            stopRetryTimer()
            play(.fail)                        // 晃动保留
        }
    }

    // MARK: 采样

    /// 采样代数:轮询(10s)与重试(1s)两条路径都会触发采样,后台读库完成时若已有
    /// 更新一轮在读,旧结果直接丢弃——乱序应用会让相位日志与灯效来回跳
    private var sampleGeneration = 0

    /// 全部采样 IO 在后台:SQLite 读(busy_timeout 400ms)+ 桥接 JSON + 相位收敛
    /// (桥接缺失时相位收敛还会扫 6 小时 OSLog)——任何一项都不可上主线程
    private func refresh(force: Bool = false) {
        guard activeIndex != nil else { return }
        sampleGeneration += 1
        let generation = sampleGeneration
        Task.detached(priority: .utility) { [weak self] in
            let reading = HeatmapStore.readToday()
            let bridge = HeatmapProbe.bridgeState()
            let truth = HeatmapProbe.phase(reading: reading)
            await MainActor.run { [weak self] in
                guard let self, self.sampleGeneration == generation else { return }
                self.applySample(
                    reading: reading,
                    bridgeToday: bridge?.today,
                    truth: Phase(rawValue: truth.rawValue) ?? .off,
                    force: force
                )
            }
        }
    }

    /// 采样结果应用到灯效状态机(主线程)
    private func applySample(
        reading: Result<HeatmapReading, HeatmapStoreError>,
        bridgeToday: Int64?,
        truth: Phase,
        force: Bool
    ) {
        var value: Int64 = shownValue
        switch reading {
        case let .success(data): value = data.today
        case .failure: break
        }
        if let bridgeToday, bridgeToday > value {
            value = bridgeToday
        }

        let previousTruth = probePhase
        probePhase = truth
        if previousTruth != truth {
            onLog?("热力图键：相位 \(previousTruth.rawValue) → \(truth.rawValue)（今日 \(value)）")
        }

        // 数值变化
        if value != shownValue {
            let crossedMidnight = value < shownValue && shownValue > 0
            play(crossedMidnight ? .midnight : .tick, from: shownValue, to: value)
            shownValue = value
        }

        // 相位流转（重试/恢复过程中不要被轮询打断）
        if phase != .retrying, phase != .recovered {
            if truth == .attention, previousTruth != .attention {
                play(.enterAttention)
            } else {
                phase = truth
                if force, transition == nil { renderStatic() }
            }
        } else if truth == .normal, phase == .retrying {
            // 由 evaluateRetry 负责切到 .recovered
        } else if force, transition == nil {
            renderStatic()
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

    /// 睡眠期间定时器不跑，唤醒/登录后必须主动刷新一次：立刻 + 2 秒后各一次。
    private func observeSystemActivation() {
        guard activationObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.activeIndex != nil else { return }
                    self.onLog?("热力图键：系统唤醒/会话激活 → 立即刷新")
                    self.refresh(force: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.refresh(force: true)
                    }
                }
            }
            activationObservers.append(token)
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

    // MARK: 转场

    private func play(_ kind: Transition.Kind, from: Int64? = nil, to: Int64? = nil) {
        let total: Int
        switch kind {
        case .tick: total = 8
        case .enterAttention: total = 3
        case .fail: total = 4
        case .press: total = 2
        case .midnight: total = 4
        }
        transition = Transition(kind: kind, frame: 0, total: total,
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
        if var current = transition {
            current.frame += 1
            if current.frame >= current.total {
                transition = nil
                if current.kind == .enterAttention { phase = .attention }
                if phase != .retrying, phase != .recovered { stopFrameTimer() }
                renderStatic()
                return
            }
            transition = current
            render()
            return
        }
        // 无转场时的持续节拍：重试红闪、恢复绿闪
        switch phase {
        case .retrying:
            blinkTicks += 1
            renderStatic()
        case .recovered:
            blinkTicks += 1
            if blinkTicks >= 12 {                 // 两次闪烁结束 → 回白灯
                blinkTicks = 0
                phase = .normal
                stopFrameTimer()
            }
            renderStatic()
        default:
            stopFrameTimer()
        }
    }

    private func finishTransitionIfNeeded() {
        transition = nil
        if phase != .retrying, phase != .recovered { stopFrameTimer() }
        renderStatic()
    }

    // MARK: 渲染

    private func phaseLook() -> HeatmapScene {
        var scene = HeatmapScene(numberFrom: displayText, numberTo: displayText)
        switch phase {
        case .normal:
            scene.lamp = .white
            scene.lampIntensity = 0.92
        case .attention:
            scene.alpha = 0                           // 数字退场
            scene.prompt = "已中断"; scene.promptAlpha = 1
            scene.lamp = .red; scene.lampIntensity = 0.95
        case .retrying:
            scene.alpha = 0
            scene.prompt = "重试中"; scene.promptAlpha = 0.8
            scene.lamp = .red
            scene.lampIntensity = (blinkTicks % 12) < 6 ? 0.95 : 0    // L3：6 亮 / 6 灭
        case .recovered:
            scene.lamp = .green
            scene.lampIntensity = (blinkTicks % 6) < 3 ? 0.95 : 0     // L4：3 亮 / 3 灭 ×2
        case .off, .unreadable:
            scene = HeatmapScene(numberFrom: "X", numberTo: "X")
            scene.prompt = "X"; scene.promptAlpha = 1
            scene.promptSize = 34
            scene.promptColor = StatTileRenderer.color("#8E8A87")
            scene.alpha = 0
            scene.lamp = .gray; scene.lampIntensity = 0.55
        }
        return scene
    }

    private func renderStatic() {
        emit(phaseLook())
    }

    private var displayText: String {
        switch phase {
        case .off, .unreadable: return "X"
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
            scene.lamp = .white; scene.lampIntensity = 0.92
            scene.flash = max(0, 1 - CGFloat(t.frame) / 2.4)
        case .enterAttention:
            scene.alpha = 1 - p                       // 数字淡出
            scene.prompt = "已中断"
            scene.promptAlpha = p                     // 文字原位淡入
            scene.lamp = .red
            scene.lampIntensity = 0.92 + 0.03 * p
            scene.numberFrom = displayText
            scene.numberTo = displayText
        case .fail:
            scene.alpha = 0
            scene.prompt = "已中断"; scene.promptAlpha = 1
            scene.lamp = .red; scene.lampIntensity = 0.95
            scene.shake = [0, 2, -2, 1][min(3, t.frame)]
        case .press:
            scene = phaseLook()
            scene.dim = 1 - p
            scene.sheen = 1 - p
        case .midnight:
            scene.roll = eased
            scene.lamp = .white; scene.lampIntensity = 0.92
        }
        emit(scene)
    }

    private func emit(_ scene: HeatmapScene) {
        guard let image = HeatmapRenderer.image(scene: scene, side: size) else { return }
        onFrame?(image)
    }

    /// 编辑器预览：当前相位的静息帧
    func previewImage(size: Int) -> CGImage? {
        var scene = phaseLook()
        if phase == .retrying { scene.lampIntensity = 0.95 }
        if phase == .recovered { scene.lampIntensity = 0.95 }
        return HeatmapRenderer.image(scene: scene, side: size)
    }

    private func easeOut(_ p: CGFloat) -> CGFloat {
        let c = min(1, max(0, p))
        return 1 - pow(1 - c, 3)
    }
}
