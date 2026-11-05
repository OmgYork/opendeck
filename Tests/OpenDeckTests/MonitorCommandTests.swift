import Foundation
import Testing

@testable import OpenDeck

/// 显示器动作目录 + 与 KeyAction 的编解码契约。
/// 校准后改了 VCP 表，这些断言会第一时间暴露缺口（漏分组、漏标签、编解码漂移）。
@Suite("显示器 DDC 动作目录")
@MainActor
struct MonitorCommandTests {
    @Test("每个命令都有分组、标签、图标与 VCP 语义")
    func catalogIsComplete() {
        for command in MonitorCommand.allCases {
            #expect(!command.title.isEmpty, "\(command.rawValue) 缺标签")
            #expect(!command.symbol.isEmpty, "\(command.rawValue) 缺图标")
            #expect(MonitorGroup.allCases.contains(command.group), "\(command.rawValue) 分组未知")
            // 0xF4 走备用寻址；其余码必须有明确操作语义
            switch command.spec.op {
            case .step(let delta):
                #expect(delta != 0, "\(command.rawValue) 步长为 0")
            case .manualTempStep(let delta):
                #expect(delta != 0, "\(command.rawValue) 色温步长为 0")
            case .set:
                break
            case .switchInput(let mac, let pc):
                #expect(command.spec.code == 0xF4)
                #expect(mac != pc)
                #expect(mac == 208 && pc == 144, "输入源编码需与 lg-toggle.sh 一致")
            }
        }
    }

    @Test("分组覆盖全部命令，托盘不会漏项")
    func groupsCoverAllCommands() {
        let grouped = MonitorGroup.allCases.flatMap { group in
            MonitorCommand.allCases.filter { $0.group == group }
        }
        #expect(grouped.count == MonitorCommand.allCases.count)
        #expect(MonitorCommand.allCases.allSatisfy { grouped.contains($0) })
    }

    @Test("KeyAction.monitor 编解码往返稳定")
    func keyActionCodableRoundTrip() throws {
        let original = KeyAction.monitor(.brightnessUp)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyAction.self, from: data)
        #expect(decoded == original)
    }

    @Test("键配置连同显示器动作一起落盘再读回")
    func keyConfigRoundTrip() throws {
        let config = KeyConfig(title: "亮度 +", action: .monitor(.brightnessUp))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(KeyConfig.self, from: data)
        #expect(decoded.action == .monitor(.brightnessUp))
        #expect(decoded.title == "亮度 +")
    }

    @Test("拖拽负载可编码为 Transferable 使用的类型标识")
    func dragPayloadIsCodable() throws {
        let data = try JSONEncoder().encode(MonitorCommand.inputToggle)
        let decoded = try JSONDecoder().decode(MonitorCommand.self, from: data)
        #expect(decoded == .inputToggle)
    }
}

// MARK: - §6.26 深度审计轮新增闸门

extension MonitorCommandTests {
    /// 确定性输入命令的乐观目标 = 命令目标本身;toggle/其余 = 磁盘状态取反。
    /// 旧逻辑一律取反:「已在 Mac 按『切到 Mac』」被演成反向迁移 + 红色回退
    @Test("MonitorInput 乐观目标:确定性命令取命令方向")
    @MainActor
    func optimisticTargetFollowsDeterministicCommand() {
        // 已在 Mac 时按「切到 Mac」:目标 = Mac(不播反向迁移,按压方按「已在目标」处理)
        #expect(MonitorInputAnimator.optimisticTarget(command: .monitor(.inputMac), disk: .mac) == .mac)
        #expect(MonitorInputAnimator.optimisticTarget(command: .monitor(.inputMac), disk: .pc) == .mac)
        #expect(MonitorInputAnimator.optimisticTarget(command: .monitor(.inputPC), disk: .pc) == .pc)
        // toggle 仍取反
        #expect(MonitorInputAnimator.optimisticTarget(command: .monitor(.inputToggle), disk: .mac) == .pc)
        // 无命令(旧调用方)保持取反语义
        #expect(MonitorInputAnimator.optimisticTarget(command: nil, disk: .pc) == .mac)
    }
}
