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

    /// 启动周期采样(幂等)。槽位清单随后由 setSlots 按当前页配置对账。
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // 趋势显示不需要精确节拍,允许系统合并定时器唤醒省电(与另两个 animator 一致)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh() // 立即采一轮,首帧不等待
    }

    /// 槽位对账:AppModel 在 applyKey/整页刷新/启动时调用。
    /// 清单变化立即重渲一轮(新统计键不等 2s 节拍;移除的槽位自然不再出帧,旧帧由常规渲染覆盖)。
    /// 对比必须含 kind:同键把 GPU 改成 CPU 时槽位号不变,只比 index 会漏掉这次对账。
    func setSlots(_ slots: [(index: Int, kind: StatKind)]) {
        guard Self.slotsListChanged(self.slots, slots) else { return }
        self.slots = slots
        refresh()
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

    /// 采样是 IOKit/注册表 IO(SMC 枚举首次可达百毫秒级),后台执行
    private func refresh() {
        generation += 1
        // 磁贴未放置 = 不实际运行:当前页(乃至全部页)没有统计键就不采样,
        // 定时器空转无害,IO 只在真的有键要看时才发生(原则:零件在盘上不通电)
        guard !slots.isEmpty else { return }
        let generation = self.generation
        let sampler = sampler
        Task.detached(priority: .utility) { [weak self] in
            let sample = sampler.sample()
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.apply(sample)
            }
        }
    }

    private func apply(_ sample: StatSample) {
        lastSample = sample
        for (index, kind) in slots {
            if let image = StatTileRenderer.tile(kind: kind, value: valueText(kind)) {
                onFrame?(index, image)
            }
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
