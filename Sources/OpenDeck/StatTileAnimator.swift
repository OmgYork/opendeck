import CoreGraphics
import Foundation

/// Stats 瓷贴的节拍器——与 KeyboardHeatmapAnimator / MonitorInputAnimator 同构的
/// 整帧驱动系统(接入约定见 docs/subsystem-integration.md)。
///
/// 职责:2s 周期后台采样(CPU/GPU/温度)→ 主线程渲染统计键整帧。
/// 2026-11-01 随 KeyAction.stat 动作化改为**配置驱动的动态槽位**:
/// 槽位清单由 AppModel.syncStatSlots 按当前页配置对账(setSlots),不再固定保留槽。
@MainActor
final class StatTileAnimator {
    /// 每槽帧回调(AppModel 负责写设备 + UI 镜像;stats 可服务多颗键,故带 index)
    var onFrame: ((Int, CGImage) -> Void)?

    /// 最近一次采样(占位帧渲染用;nil = 尚无数据)
    private(set) var lastSample: StatSample?

    private var slots: [(index: Int, kind: StatKind)] = []
    private let sampler = StatSampler()
    private var timer: Timer?
    /// 过渡帧播放器(§6.33):值变化的弧线扫摆。onFrame 转发给自身回调——
    /// 不接线的话 sweep 帧与终帧全部发往 nil,瓷贴永远停在 applyKey 的占位帧(踩过)
    private let fx = TileFXPlayer()
    /// 触发扫摆的最小分率跳变(0.10 = 10 个百分点);微动直接换帧(性能守卫)
    static let sweepThreshold = 0.10
    /// 扫摆冷却:同键 8s 内至多一扫——利用率波动常跨阈值,无冷却则扫摆逐轮高频
    /// (§6.35 实测 +6% CPU);巨变(≥ hugeJumpThreshold)豁免冷却
    static let sweepCooldown: TimeInterval = 8
    static let hugeJumpThreshold = 0.50
    private var lastSweepAt: [Int: Date] = [:]

    init() {
        fx.onFrame = { [weak self] index, image in
            self?.onFrame?(index, image)
        }
    }
    /// 上次渲染的值文本与弧分率(键位键控):变化检测 + 扫摆起点
    private var lastValues: [Int: (text: String, fraction: Double)] = [:]

    /// 采样代数:后台采样完成时若已有更新一轮在采,旧结果丢弃(乱序覆盖会闪旧值)
    private var generation = 0
    /// 在飞标志:重叠采样只是重复 IO(SMC/注册表查询),单飞后完成时补一轮挂起的立即请求
    private var inFlight = false
    private var pendingRefresh = false
    /// 上帧值文本(按 index 键控):温度常分钟级不变,值未变的重渲+JPEG+HID 是纯浪费。
    /// setSlots 清单变化时整表作废(同键换指标 GPU→CPU 时文本可能相同,不能只比文本)
    private var lastValueTexts: [Int: String] = [:]

    /// 启动周期采样(幂等)。定时器实际随槽位清单启停(setSlots 管理):
    /// 零统计键时不空转(0.5 次/s 的定时器唤醒,原则:零件在盘上不通电)
    func start() {
        guard timer == nil, !slots.isEmpty else { return }
        ensureTimer()
        refresh() // 立即采一轮,首帧不等待
    }

    /// 槽位对账:AppModel 在 applyKey/整页刷新/启动时调用。
    /// 清单变化立即重渲一轮(新统计键不等 2s 节拍;移除的槽位自然不再出帧,旧帧由常规渲染覆盖)。
    /// 对比必须含 kind:同键把 GPU 改成 CPU 时槽位号不变,只比 index 会漏掉这次对账。
    func setSlots(_ slots: [(index: Int, kind: StatKind)]) {
        guard Self.slotsListChanged(self.slots, slots) else { return }
        self.slots = slots
        lastValues.removeAll()
        fx.stopAll()
        if slots.isEmpty {
            timer?.invalidate()
            timer = nil
        } else {
            ensureTimer()
            refresh()
        }
    }

    /// 清单是否变化(index 与 kind 都要比;供对账守卫与单测共用)
    static func slotsListChanged(
        _ a: [(index: Int, kind: StatKind)],
        _ b: [(index: Int, kind: StatKind)]
    ) -> Bool {
        a.map(\.index) != b.map(\.index) || a.map(\.kind) != b.map(\.kind)
    }

    /// 占位帧:applyKey 在首帧采样未回来时使用(有值显值,无值显 "--")
    func placeholderTile(kind: StatKind) -> CGImage? {
        StatTileRenderer.tile(kind: kind, value: valueText(kind))
            ?? StatTileRenderer.tile(kind: kind, value: "--")
    }

    // MARK: 私有

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // 趋势显示不需要精确节拍,允许系统合并定时器唤醒省电(与另两个 animator 一致)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 采样是 IOKit/注册表 IO(SMC 枚举首次可达百毫秒级),后台执行
    private func refresh() {
        guard !slots.isEmpty else { return }
        if inFlight {
            // 磁贴未放置 = 不实际运行;在飞未完 = 排队补一轮而非重叠采样
            pendingRefresh = true
            return
        }
        inFlight = true
        let generation = self.generation + 1
        self.generation = generation
        let sampler = sampler
        Task.detached(priority: .utility) { [weak self] in
            let sample = sampler.sample()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight = false
                // 先补挂起请求再应用结果:pending 的补采样会把更新槽位清单一起覆盖
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.refresh()
                }
                guard self.generation == generation else { return }
                self.apply(sample)
            }
        }
    }

    private func apply(_ sample: StatSample) {
        lastSample = sample
        for (index, kind) in slots {
            let text = valueText(kind)
            guard lastValues[index]?.text != text else { continue } // 值未变零成本(既有守卫)
            let number = numericValue(text)
            let fraction = StatTileRenderer.fraction(kind: kind, celsiusOrPercent: number ?? 0)
            guard let image = StatTileRenderer.tile(kind: kind, value: text, fraction: fraction) else { continue }
            let previous = lastValues[index]
            lastValues[index] = (text, fraction)
            // 扫摆只给「有意义的跳变」:首帧从 0 填满(每次挂载一次,衔接自然)、
            // 分率跳变 ≥ sweepThreshold(大跨越值得动画)。利用率逐样本 ±几个点的
            // 微动直接换帧——否则每轮采样 6 帧 × 3 键 = 9fps 渲染+编码+HID 纯增(实测 +6% CPU)
            let fromFraction = previous?.fraction ?? 0
            let delta = abs(fraction - fromFraction)
            let now = Date()
            let cooledDown = now.timeIntervalSince(lastSweepAt[index] ?? .distantPast) >= Self.sweepCooldown
            if previous == nil || delta >= Self.hugeJumpThreshold
                || (delta >= Self.sweepThreshold && cooledDown) {
                lastSweepAt[index] = now
                let frames = StatTileRenderer.sweepFrames(kind: kind, fromFraction: fromFraction,
                                                          toFraction: fraction, value: text)
                fx.play(index: index, frames: frames, final: image)
            } else {
                onFrame?(index, image)
            }
        }
    }

    private func numericValue(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "°", with: "")
        return Double(cleaned)
    }

    private func valueText(_ kind: StatKind) -> String {
        guard let sample = lastSample else { return "--" }
        switch kind {
        case .gpu: return sample.gpu.map { "\($0)%" } ?? "--"
        case .cpu: return sample.cpu.map { "\($0)%" } ?? "--"
        case .temp: return sample.temp.map { "\(Int($0.rounded()))°" } ?? "--"
        }
    }
}
