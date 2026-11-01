import Foundation
import Testing

@testable import OpenDeck

/// 统计槽位对账守卫:setSlots 必须对「同槽位换指标」敏感。
/// 回归背景:守卫曾只比槽位号列表,同一键 GPU 改 CPU 后 2s 节拍器永远画回旧指标。
@Suite("统计槽位对账")
@MainActor
struct StatSlotReconcileTests {
    @Test("同槽位换指标视为变化")
    func kindChangeOnSameIndex() {
        let before = [(index: 4, kind: StatKind.gpu)]
        let after = [(index: 4, kind: StatKind.cpu)]
        #expect(StatTileAnimator.slotsListChanged(before, after))
    }

    @Test("槽位增删与跨槽换位均视为变化")
    func addRemoveAndSwap() {
        let base = [(index: 2, kind: StatKind.gpu), (index: 9, kind: StatKind.temp)]
        #expect(StatTileAnimator.slotsListChanged(base, []))                    // 全部移除
        #expect(StatTileAnimator.slotsListChanged(base, base + [(index: 0, kind: StatKind.cpu)])) // 新增
        #expect(StatTileAnimator.slotsListChanged(base, [(index: 9, kind: StatKind.gpu), (index: 2, kind: StatKind.temp)])) // 互换
    }

    @Test("清单未变不触发重渲")
    func unchangedList() {
        let base = [(index: 2, kind: StatKind.gpu), (index: 9, kind: StatKind.temp)]
        #expect(!StatTileAnimator.slotsListChanged(base, base))
        #expect(!StatTileAnimator.slotsListChanged([], []))
    }
}
