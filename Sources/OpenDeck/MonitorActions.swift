import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// MARK: - 显示器 DDC 动作（语义层）
//
// 一个 MonitorCommand = 一个键动作的完整语义：VCP 码 + 运算方式 + 呈现文案。
// 校准结果（新的码、新的枚举值）只改这里，不动执行层与渲染层。
//
// 状态标注（对应 ~/projects/lg-osc/FEATURES.md 的分级）：
//   confirmed = 已在本机实测写入并回读一致
//   draft     = 读到合理值、编码来自同族调研，待 OSD 校准确认
//   pending   = 私有码语义未知，仍未接线

/// 托盘分组（顺序即渲染顺序）
enum MonitorGroup: String, CaseIterable, Identifiable {
    case picture
    case game
    case audio
    case input

    var id: String { rawValue }

    var title: String {
        switch self {
        case .picture: "画面"
        case .game: "游戏"
        case .audio: "音频"
        case .input: "输入"
        }
    }
}

/// 单条动作的 DDC 语义
struct MonitorSpec {
    enum Op {
        /// 相对调节：当前值 + delta，钳制在 0…max
        case step(Int)
        /// 枚举循环：按给定顺序取下一档（当前值不在表内则取第一档）
        case cycle([Int])
        /// 直接写固定值
        case set(Int)
        /// 输入源切换（0xF4 走另一套寻址），值 = (Mac, PC)
        case switchInput(mac: Int, pc: Int)
    }

    let code: UInt8
    let op: Op
    /// 校准状态备注（显示在托盘 tooltip）
    var note: String? = nil
    /// 写入会让 DP 链路重协商、画面闪断十余秒
    var disruptive: Bool = false
}

enum MonitorCommand: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    // 画面
    case brightnessDown
    case brightnessUp
    case contrastDown
    case contrastUp
    case sharpnessDown
    case sharpnessUp
    case gammaCycle

    // 游戏
    case responseTimeCycle
    case smartEnergyCycle
    case adaptiveSyncCycle
    case blackStabilizerDown
    case blackStabilizerUp

    // 音频
    case volumeDown
    case volumeUp
    case muteToggle

    // 输入
    case inputMac
    case inputPC
    case inputToggle

    var id: String { rawValue }

    /// 每个命令的 DDC 语义（校准后只改这张表）
    var spec: MonitorSpec {
        switch self {
        case .brightnessDown: MonitorSpec(code: 0x10, op: .step(-5), note: "实测可写")
        case .brightnessUp: MonitorSpec(code: 0x10, op: .step(5), note: "实测可写")
        case .contrastDown: MonitorSpec(code: 0x12, op: .step(-5), note: "标准码，实测可读")
        case .contrastUp: MonitorSpec(code: 0x12, op: .step(5), note: "标准码，实测可读")
        case .sharpnessDown: MonitorSpec(code: 0x87, op: .step(-10), note: "实测可写")
        case .sharpnessUp: MonitorSpec(code: 0x87, op: .step(10), note: "实测可写")
        case .gammaCycle: MonitorSpec(code: 0xFE, op: .cycle([1, 2, 3]), note: "待校准：枚举值随型号变")
        case .responseTimeCycle: MonitorSpec(code: 0xF7, op: .cycle([0, 1, 2, 3]), note: "实测 0…3 全档可写")
        case .smartEnergyCycle: MonitorSpec(code: 0xF6, op: .cycle([0, 1, 2]), note: "待校准：关/低/高")
        case .adaptiveSyncCycle:
            MonitorSpec(code: 0xF8, op: .cycle([0, 2, 3]), note: "实测可写；写入会闪断画面十余秒", disruptive: true)
        case .blackStabilizerDown:
            MonitorSpec(code: 0xF9, op: .step(-10), note: "待校准：本机回读异常（写 20 读回 100）")
        case .blackStabilizerUp:
            MonitorSpec(code: 0xF9, op: .step(10), note: "待校准：本机回读异常（写 20 读回 100）")
        case .volumeDown: MonitorSpec(code: 0x62, op: .step(-5), note: "标准码，实测可读")
        case .volumeUp: MonitorSpec(code: 0x62, op: .step(5), note: "标准码，实测可读")
        case .muteToggle: MonitorSpec(code: 0x8D, op: .cycle([1, 2]), note: "1=静音 2=取消（标准码）")
        case .inputMac, .inputPC, .inputToggle:
            MonitorSpec(code: 0xF4, op: .switchInput(mac: 208, pc: 144), note: "与 lg-toggle.sh 同一编码")
        }
    }

    var group: MonitorGroup {
        switch self {
        case .brightnessDown, .brightnessUp, .contrastDown, .contrastUp,
             .sharpnessDown, .sharpnessUp, .gammaCycle:
            .picture
        case .responseTimeCycle, .smartEnergyCycle, .adaptiveSyncCycle,
             .blackStabilizerDown, .blackStabilizerUp:
            .game
        case .volumeDown, .volumeUp, .muteToggle:
            .audio
        case .inputMac, .inputPC, .inputToggle:
            .input
        }
    }

    /// 托盘与键面上的短标签
    var title: String {
        switch self {
        case .brightnessDown: "亮度 −"
        case .brightnessUp: "亮度 +"
        case .contrastDown: "对比 −"
        case .contrastUp: "对比 +"
        case .sharpnessDown: "锐度 −"
        case .sharpnessUp: "锐度 +"
        case .gammaCycle: "伽马"
        case .responseTimeCycle: "响应"
        case .smartEnergyCycle: "节能"
        case .adaptiveSyncCycle: "同步"
        case .blackStabilizerDown: "黑阶 −"
        case .blackStabilizerUp: "黑阶 +"
        case .volumeDown: "音量 −"
        case .volumeUp: "音量 +"
        case .muteToggle: "静音"
        case .inputMac: "切到 Mac"
        case .inputPC: "切到 PC"
        case .inputToggle: "切换输入"
        }
    }

    var symbol: String {
        switch self {
        case .brightnessDown: "sun.min"
        case .brightnessUp: "sun.max"
        case .contrastDown: "circle.lefthalf.filled"
        case .contrastUp: "circle.righthalf.filled"
        case .sharpnessDown: "minus.magnifyingglass"
        case .sharpnessUp: "plus.magnifyingglass"
        case .gammaCycle: "camera.filters"
        case .responseTimeCycle: "speedometer"
        case .smartEnergyCycle: "leaf"
        case .adaptiveSyncCycle: "arrow.triangle.2.circlepath"
        case .blackStabilizerDown: "moonphase.waning.crescent"
        case .blackStabilizerUp: "moonphase.waxing.crescent"
        case .volumeDown: "speaker.minus"
        case .volumeUp: "speaker.plus"
        case .muteToggle: "speaker.slash"
        case .inputMac: "laptopcomputer"
        case .inputPC: "pc"
        case .inputToggle: "arrow.left.arrow.right"
        }
    }
}

// MARK: - 拖拽

extension UTType {
    /// 托盘 → 键位的内部拖拽类型
    nonisolated static let opendeckMonitorCommand = UTType(exportedAs: "com.opendeck.monitor-command")
}

extension MonitorCommand: Transferable {
    nonisolated static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .opendeckMonitorCommand)
    }
}
