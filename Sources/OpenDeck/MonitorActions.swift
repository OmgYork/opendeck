import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// MARK: - 显示器 DDC 动作（语义层）
//
// 一个 MonitorCommand = 一个键动作的完整语义：VCP 码 + 运算方式 + 呈现文案。
// 校准结果（新的码、新的枚举值）只改这里，不动执行层与渲染层。
//
// 设计原则（2026-10-23 定案）：托盘只放**原子动作**（单值 set 或单步 step），
// 复合/集成键（组合配方）不放这里 —— 它们进 MonitorCompositeCatalog。
//
// 状态标注（对应 ~/projects/lg-osc/FEATURES.md 的分级）：
//   confirmed = 已在本机实测写入并回读一致
//   draft     = 读到合理值、编码来自同族调研，待 OSD 校准确认
//   pending   = 私有码语义未知，仍未接线

/// 托盘分组（顺序即渲染顺序；composite 置顶）
nonisolated enum MonitorGroup: String, CaseIterable, Identifiable, Sendable {
    case composite
    case picture
    case game
    case audio
    case input

    var id: String { rawValue }

    var title: String {
        switch self {
        case .composite: "自定义 / 复合"
        case .picture: "画面"
        case .game: "游戏"
        case .audio: "音频"
        case .input: "输入"
        }
    }
}

/// 单条动作的 DDC 语义(纯值,无隔离要求)
nonisolated struct MonitorSpec: Sendable {
    nonisolated enum Op: Sendable {
        /// 相对调节：当前值 + delta，钳制在 0…max
        case step(Int)
        /// 直接写固定值
        case set(Int)
        /// 输入源切换（0xF4 走另一套寻址），值 = (Mac, PC)
        case switchInput(mac: Int, pc: Int)
        /// 手动色温沿 19 格刻度步进（自动先切手动档；0x69 只在手动档可写）
        case manualTempStep(Int)
    }

    let code: UInt8
    let op: Op
    /// 校准状态备注（显示在托盘 tooltip）
    var note: String? = nil
    /// 写入会让 DP 链路重协商、画面闪断十余秒
    var disruptive: Bool = false
}

nonisolated enum MonitorCommand: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    // 画面 · 亮度 / 对比 / 锐度
    case brightnessDown
    case brightnessUp
    case contrastDown
    case contrastUp
    case sharpnessDown
    case sharpnessUp

    // 画面 · 伽马（4 档，单值）
    case gamma1
    case gamma2
    case gamma3
    case gamma4

    // 画面 · 图像模式（11 档，单值）
    case picReader
    case picColorWeak
    case picSRGB
    case picCal1
    case picCal2
    case picFPS
    case picRTS
    case picHDR
    case picGame1
    case picGame2
    case picVivid

    // 画面 · 色温（预设 5 档单值 + 手动刻度 ±）
    case tempUser
    case tempWarm
    case tempNatural
    case tempCool
    case tempManual
    case tempManualDown
    case tempManualUp

    // 游戏
    case responseOff
    case responseFaster
    case responseFast
    case responseNormal
    case energyOff
    case energyLow
    case energyHigh
    case syncBasic
    case syncExtended

    // 音频
    case volumeDown
    case volumeUp
    case muteOn
    case muteOff

    // 输入
    case inputMac
    case inputPC
    case inputToggle

    var id: String { rawValue }

    /// 手动色温 19 格刻度（实测值，从暖到冷，Kelvin）
    static let manualTempLadder: [Int] = [
        4000, 4400, 4700, 5000, 5300, 5600, 5900, 6200, 6500,
        6800, 7100, 7400, 7700, 8000, 8300, 8600, 8900, 9300, 10000,
    ]

    /// 每个命令的 DDC 语义（校准后只改这张表）
    var spec: MonitorSpec {
        switch self {
        // 亮度 / 对比 / 锐度
        case .brightnessDown: MonitorSpec(code: 0x10, op: .step(-5), note: "实测可写")
        case .brightnessUp: MonitorSpec(code: 0x10, op: .step(5), note: "实测可写")
        case .contrastDown: MonitorSpec(code: 0x12, op: .step(-5), note: "标准码，实测可读")
        case .contrastUp: MonitorSpec(code: 0x12, op: .step(5), note: "标准码，实测可读")
        case .sharpnessDown: MonitorSpec(code: 0x87, op: .step(-10), note: "实测可写")
        case .sharpnessUp: MonitorSpec(code: 0x87, op: .step(10), note: "实测可写")
        // 伽马：以 0x72（MCCS Gamma）为主码，4 档 = 25600/30720/35840/40960（+5120/档）；
        // 写 0x72 时 0xFE 自动跟随（实测 35840→0xFE=4、30720→3）
        case .gamma1: MonitorSpec(code: 0x72, op: .set(25600), note: "伽马模式1（0x72 主码，0xFE 自动跟随）")
        case .gamma2: MonitorSpec(code: 0x72, op: .set(30720), note: "伽马模式2（0x72 主码，0xFE 自动跟随）")
        case .gamma3: MonitorSpec(code: 0x72, op: .set(35840), note: "伽马模式3（0x72 主码，0xFE 自动跟随）")
        case .gamma4: MonitorSpec(code: 0x72, op: .set(40960), note: "伽马模式4（0x72 主码，0xFE 自动跟随）")
        // 图像模式：11 档全枚举（显式值表）；切预设会连带改亮度/锐度/响应时间
        case .picReader: MonitorSpec(code: 0x15, op: .set(1), note: "图像模式：阅读（连带改亮度/锐度/响应）")
        case .picColorWeak: MonitorSpec(code: 0x15, op: .set(6), note: "图像模式：色弱")
        case .picSRGB: MonitorSpec(code: 0x15, op: .set(15), note: "图像模式：sRGB")
        case .picCal1: MonitorSpec(code: 0x15, op: .set(18), note: "图像模式：校准1")
        case .picCal2: MonitorSpec(code: 0x15, op: .set(19), note: "图像模式：校准2")
        case .picFPS: MonitorSpec(code: 0x15, op: .set(30), note: "图像模式：fps")
        case .picRTS: MonitorSpec(code: 0x15, op: .set(31), note: "图像模式：rts")
        case .picHDR: MonitorSpec(code: 0x15, op: .set(39), note: "图像模式：HDR 效果")
        case .picGame1: MonitorSpec(code: 0x15, op: .set(45), note: "图像模式：玩家1")
        case .picGame2: MonitorSpec(code: 0x15, op: .set(46), note: "图像模式：玩家2")
        case .picVivid: MonitorSpec(code: 0x15, op: .set(49), note: "图像模式：生动")
        // 色温预设（实测：用户11/暖3/自然5/冷9/手动65502）；切用户档会把 0x69 拉回 6500
        case .tempUser: MonitorSpec(code: 0x14, op: .set(11), note: "色温：用户（0x69 回到 6500）")
        case .tempWarm: MonitorSpec(code: 0x14, op: .set(3), note: "色温：暖色")
        case .tempNatural: MonitorSpec(code: 0x14, op: .set(5), note: "色温：自然色")
        case .tempCool: MonitorSpec(code: 0x14, op: .set(9), note: "色温：冷色")
        case .tempManual: MonitorSpec(code: 0x14, op: .set(65502), note: "色温：手动（0x69 在此档可写）")
        // 手动色温刻度：±1 格（19 格实测刻度；自动先切手动档）
        case .tempManualDown: MonitorSpec(code: 0x69, op: .manualTempStep(-1), note: "手动色温 −1 格（自动切手动档）")
        case .tempManualUp: MonitorSpec(code: 0x69, op: .manualTempStep(1), note: "手动色温 +1 格（自动切手动档）")
        // 响应时间（实测 0…3 全档可写）
        case .responseOff: MonitorSpec(code: 0xF7, op: .set(0), note: "响应时间：关")
        case .responseFaster: MonitorSpec(code: 0xF7, op: .set(1), note: "响应时间：更快")
        case .responseFast: MonitorSpec(code: 0xF7, op: .set(2), note: "响应时间：快速")
        case .responseNormal: MonitorSpec(code: 0xF7, op: .set(3), note: "响应时间：正常")
        // 智能节能（0xF6 为社区码，本机未实测写入）
        case .energyOff: MonitorSpec(code: 0xF6, op: .set(0), note: "智能节能：关（0xF6 社区码，本机未实测）")
        case .energyLow: MonitorSpec(code: 0xF6, op: .set(1), note: "智能节能：低（0xF6 社区码，本机未实测）")
        case .energyHigh: MonitorSpec(code: 0xF6, op: .set(2), note: "智能节能：高（0xF6 社区码，本机未实测）")
        // 自适应同步：只做「基本/扩展」——0=关 会让 OSD 的 OC 置灰、已开的 OC 被连带锁掉，
        // 且 DDC 读不到 OC 锁定状态；写入本身会闪断画面十余秒
        case .syncBasic: MonitorSpec(code: 0xF8, op: .set(2), note: "自适应同步：基本（闪断十余秒）", disruptive: true)
        case .syncExtended: MonitorSpec(code: 0xF8, op: .set(3), note: "自适应同步：扩展（闪断十余秒）", disruptive: true)
        // 音频
        case .volumeDown: MonitorSpec(code: 0x62, op: .step(-5), note: "标准码，实测可读")
        case .volumeUp: MonitorSpec(code: 0x62, op: .step(5), note: "标准码，实测可读")
        case .muteOn: MonitorSpec(code: 0x8D, op: .set(1), note: "静音（标准码 0x8D=1）")
        case .muteOff: MonitorSpec(code: 0x8D, op: .set(2), note: "取消静音（标准码 0x8D=2）")
        // 输入源：实测闭环（2026-10-23）144=HDMI1(PC) / 208=DP(Mac)；切换期间 DDC 不掉。
        // 0xF4 不可读、0x60 只回缓存 → toggle 方向靠 ~/.cache/lg_input
        case .inputMac, .inputPC, .inputToggle:
            MonitorSpec(code: 0xF4, op: .switchInput(mac: 208, pc: 144),
                        note: "实测闭环：144=HDMI1(PC) / 208=DP(Mac)，切换时 DDC 不掉")
        }
    }

    var group: MonitorGroup {
        switch self {
        case .brightnessDown, .brightnessUp, .contrastDown, .contrastUp,
             .sharpnessDown, .sharpnessUp,
             .gamma1, .gamma2, .gamma3, .gamma4,
             .picReader, .picColorWeak, .picSRGB, .picCal1, .picCal2,
             .picFPS, .picRTS, .picHDR, .picGame1, .picGame2, .picVivid,
             .tempUser, .tempWarm, .tempNatural, .tempCool, .tempManual,
             .tempManualDown, .tempManualUp:
            .picture
        case .responseOff, .responseFaster, .responseFast, .responseNormal,
             .energyOff, .energyLow, .energyHigh,
             .syncBasic, .syncExtended:
            .game
        case .volumeDown, .volumeUp, .muteOn, .muteOff:
            .audio
        case .inputMac, .inputPC, .inputToggle:
            .input
        }
    }

    /// 组内小节标题（托盘按此分层；顺序 = allCases 声明顺序）
    var subgroup: String {
        switch self {
        case .brightnessDown, .brightnessUp, .contrastDown, .contrastUp,
             .sharpnessDown, .sharpnessUp:
            "亮度 / 对比 / 锐度"
        case .gamma1, .gamma2, .gamma3, .gamma4:
            "伽马"
        case .picReader, .picColorWeak, .picSRGB, .picCal1, .picCal2,
             .picFPS, .picRTS, .picHDR, .picGame1, .picGame2, .picVivid:
            "图像模式"
        case .tempUser, .tempWarm, .tempNatural, .tempCool, .tempManual,
             .tempManualDown, .tempManualUp:
            "色温"
        case .responseOff, .responseFaster, .responseFast, .responseNormal:
            "响应"
        case .energyOff, .energyLow, .energyHigh:
            "节能"
        case .syncBasic, .syncExtended:
            "同步"
        case .volumeDown, .volumeUp:
            "音量"
        case .muteOn, .muteOff:
            "静音"
        case .inputMac, .inputPC, .inputToggle:
            "输入切换"
        }
    }

    /// 组内小节（按声明顺序去重）
    static func subgroups(in group: MonitorGroup) -> [String] {
        var result: [String] = []
        for command in allCases where command.group == group {
            if !result.contains(command.subgroup) { result.append(command.subgroup) }
        }
        return result
    }

    /// 输入类动作绑定键位时自动附带动效键面（显示当前输入源图标/翻转动画，与槽位 1 同款）
    var carriesInputAnimation: Bool {
        switch self {
        case .inputMac, .inputPC, .inputToggle: true
        default: false
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
        case .gamma1: "伽马1"
        case .gamma2: "伽马2"
        case .gamma3: "伽马3"
        case .gamma4: "伽马4"
        case .picReader: "图像·阅读"
        case .picColorWeak: "图像·色弱"
        case .picSRGB: "图像·sRGB"
        case .picCal1: "图像·校准1"
        case .picCal2: "图像·校准2"
        case .picFPS: "图像·fps"
        case .picRTS: "图像·rts"
        case .picHDR: "图像·HDR效果"
        case .picGame1: "图像·玩家1"
        case .picGame2: "图像·玩家2"
        case .picVivid: "图像·生动"
        case .tempUser: "色温·用户"
        case .tempWarm: "色温·暖色"
        case .tempNatural: "色温·自然色"
        case .tempCool: "色温·冷色"
        case .tempManual: "色温·手动"
        case .tempManualDown: "手动色温 −"
        case .tempManualUp: "手动色温 +"
        case .responseOff: "响应·关"
        case .responseFaster: "响应·更快"
        case .responseFast: "响应·快速"
        case .responseNormal: "响应·正常"
        case .energyOff: "节能·关"
        case .energyLow: "节能·低"
        case .energyHigh: "节能·高"
        case .syncBasic: "同步·基本"
        case .syncExtended: "同步·扩展"
        case .volumeDown: "音量 −"
        case .volumeUp: "音量 +"
        case .muteOn: "静音"
        case .muteOff: "取消静音"
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
        case .gamma1: "1.circle"
        case .gamma2: "2.circle"
        case .gamma3: "3.circle"
        case .gamma4: "4.circle"
        case .picReader: "book"
        case .picColorWeak: "eye"
        case .picSRGB: "camera"
        case .picCal1: "slider.horizontal.3"
        case .picCal2: "slider.horizontal.3"
        case .picFPS: "scope"
        case .picRTS: "flag"
        case .picHDR: "sun.haze"
        case .picGame1: "gamecontroller"
        case .picGame2: "gamecontroller"
        case .picVivid: "sparkles"
        case .tempUser: "person"
        case .tempWarm: "sun.max"
        case .tempNatural: "leaf"
        case .tempCool: "snowflake"
        case .tempManual: "slider.horizontal.3"
        case .tempManualDown: "minus.circle"
        case .tempManualUp: "plus.circle"
        case .responseOff: "xmark.circle"
        case .responseFaster: "hare"
        case .responseFast: "forward"
        case .responseNormal: "gauge.medium"
        case .energyOff: "xmark.circle"
        case .energyLow: "leaf"
        case .energyHigh: "leaf.fill"
        case .syncBasic: "arrow.triangle.2.circlepath"
        case .syncExtended: "arrow.triangle.2.circlepath"
        case .volumeDown: "speaker.minus"
        case .volumeUp: "speaker.plus"
        case .muteOn: "speaker.slash"
        case .muteOff: "speaker.wave.2"
        case .inputMac: "laptopcomputer"
        case .inputPC: "pc"
        case .inputToggle: "arrow.left.arrow.right"
        }
    }
}

// MARK: - 自定义 / 复合键（托盘置顶分类）
//
// 复合键 = 动作 + 动效 的完整配方（一个载荷一次绑定）。
// 托盘里的原子磁贴只是「零件」；把零件组装成复合键的成品放这里。

/// 「自定义/复合」磁贴：绑定即写入 action + animation
struct MonitorCompositeTile: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let note: String
    let action: KeyAction
    let animation: KeyAnimation?

    /// 拖拽/点选载荷（与 MonitorCommand.rawValue 同域，用前缀区分）
    var payload: String { "composite:" + id }
}

enum MonitorCompositeCatalog {
    static let all: [MonitorCompositeTile] = [
        MonitorCompositeTile(
            id: "inputToggleAnimated",
            title: "输入切换（动效）",
            symbol: "arrow.left.arrow.right",
            note: "原生 toggle（读 ~/.cache/lg_input 定方向）+ 输入源动效键面；槽位 1 同款",
            action: .monitor(.inputToggle),
            animation: .monitorInput
        ),
        // 槽位 4「游戏模式 FPS·4:3」组合键在组合动作落地后加入这里
    ]

    /// 从载荷解析复合磁贴（非 composite: 前缀返回 nil）
    static func tile(payload: String) -> MonitorCompositeTile? {
        guard payload.hasPrefix("composite:") else { return nil }
        let id = String(payload.dropFirst("composite:".count))
        return all.first { $0.id == id }
    }
}

// MARK: - 拖拽
//
// 拖拽载荷走纯文本(见 FunctionPaletteCatalog.swift 头注释):自定义 UTType
// 在宿主 NSView 上不保证被接受,历史上的 Transferable 声明已随死代码清理移除。
