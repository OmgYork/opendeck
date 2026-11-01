import Foundation
import StreamDockKit

/// 固定保留槽策略:全页强制占用的键位(仅末两格导航;Stats 已于 2026-11-01 动作化,
/// 见 KeyAction.stat——统计键可放任意键位、可清除,不再占保留槽)。
///
/// 这是宿主契约的一部分,也是外部(编辑器)判断「该格能不能编辑」的唯一依据:
/// `slot(at:) == nil` 才是用户槽。坐标一律 0-based(`index = row * columns + column`)。
enum ReservedSlots {
    /// 保留槽语义:导航键强制动作+箭头瓷贴
    enum Slot {
        case nav(KeyAction, tile: KeyConfig)
    }

    /// 末两格(位置 14/15)导航,全页保留,不读配置、不可编辑
    static func slot(at index: Int) -> Slot? {
        switch index {
        case 13: return .nav(.nextScene, tile: KeyConfig(title: "↔", backgroundColorHex: "#5E81AC", action: .nextScene))
        case 14: return .nav(.nextPage, tile: KeyConfig(title: "↕", backgroundColorHex: "#B48EAD", action: .nextPage))
        default: return nil
        }
    }

    /// 键位最终生效配置:保留槽强制保留瓷贴,其余读用户配置
    static func keyConfig(at index: Int, config: ConfigStore) -> KeyConfig {
        guard let slot = slot(at: index) else { return config.keyConfig(at: index) }
        switch slot {
        case .nav(_, let tile): return tile
        }
    }
}
