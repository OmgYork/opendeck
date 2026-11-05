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
        lastValueTexts.removeAll()
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
            guard lastValueTexts[index] != text else { continue }
            guard let image = StatTileRenderer.tile(kind: kind, value: text) else { continue }
            lastValueTexts[index] = text
            onFrame?(index, image)
        }
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
