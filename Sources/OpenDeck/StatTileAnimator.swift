import CoreGraphics
import Foundation

/// Stats 瓷贴的节拍器——与 KeyboardHeatmapAnimator / MonitorInputAnimator 同构的
/// 整帧驱动系统(接入约定见 docs/subsystem-integration.md)。
///
/// 职责:2s 周期后台采样(CPU/GPU/温度)→ 主线程渲染保留槽整帧。
/// 生命周期跟应用走(Stats 槽全页保留,不随页面挂卸,与另两个 animator 的
/// attach/detach 模式不同);启动后由采样定时器持续驱动。
@MainActor
final class StatTileAnimator {
    /// 每槽帧回调(AppModel 负责写设备 + UI 镜像;stats 服务多颗保留槽,故带 index)
    var onFrame: ((Int, CGImage) -> Void)?

    /// 最近一次采样(占位帧渲染用;nil = 尚无数据)
    private(set) var lastSample: StatSample?

    private var slots: [(index: Int, kind: StatKind)] = []
    private let sampler = StatSampler()
    private var timer: Timer?

    /// 采样代数:后台采样完成时若已有更新一轮在采,旧结果丢弃(乱序覆盖会闪旧值)
    private var generation = 0

    /// 启动周期采样(幂等)。slots 为保留槽清单(index 0-based)。
    func start(slots: [(index: Int, kind: StatKind)]) {
        guard timer == nil else { return }
        self.slots = slots
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // 趋势显示不需要精确节拍,允许系统合并定时器唤醒省电(与另两个 animator 一致)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh() // 立即采一轮,首帧不等待
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
