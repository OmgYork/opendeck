import Foundation
import StreamDockKit

/// 固定保留槽策略:全页强制占用的键位(末两格导航 + 中排前三格 Stats)。
///
/// 这是宿主契约的一部分,也是外部(编辑器)判断「该格能不能编辑」的唯一依据:
/// `slot(at:) == nil` 才是用户槽。坐标一律 0-based(`index = row * columns + column`)。
///
/// 纯搬移:槽位编号、瓷贴底色、占位标题、Stats 顺序与拆分前一致。
enum ReservedSlots {
    /// 保留槽语义:导航键强制动作+箭头瓷贴;Stats 槽由采样定时器整帧覆盖,按压无动作
    enum Slot {
        case nav(KeyAction, tile: KeyConfig)
        case stat(StatKind)
    }

    /// 末两格(位置 14/15)导航 + 中排前三格(位置 6/7/8)Stats,全页保留,不读配置、不可编辑
    static func slot(at index: Int) -> Slot? {
        switch index {
        case 13: return .nav(.nextScene, tile: KeyConfig(title: "↔", backgroundColorHex: "#5E81AC", action: .nextScene))
        case 14: return .nav(.nextPage, tile: KeyConfig(title: "↕", backgroundColorHex: "#B48EAD", action: .nextPage))
        case 5: return .stat(.gpu)
        case 6: return .stat(.cpu)
        case 7: return .stat(.temp)
        default: return nil
        }
    }

    /// Stats 槽位(索引):GPU 6 / CPU 7 / 温度 8
    static let statSlots: [(index: Int, kind: StatKind)] = [
        (5, .gpu), (6, .cpu), (7, .temp),
    ]

    /// 键位最终生效配置:保留槽强制保留瓷贴(Stats 槽在首帧采样前显示占位),其余读用户配置
    static func keyConfig(at index: Int, config: ConfigStore) -> KeyConfig {
        guard let slot = slot(at: index) else { return config.keyConfig(at: index) }
        switch slot {
        case .nav(_, let tile): return tile
        case .stat(let kind): return KeyConfig(title: kind.label, backgroundColorHex: "#3B4252")
        }
    }
}
