import CoreGraphics
import Foundation
import Testing

@testable import OpenDeck

/// 热键 = 键盘按键能力:修饰键作主键的注入位表、录制判定表、显示与编解码契约。
/// 设备位取值 HIToolbox/Events.h 的 NX_DEVICExxxKEYMASK——区分左右键的接收方
/// (Raycast/BTT 等)靠设备位识别物理键,这些断言钉住位值不被改错。
@Suite("热键键盘按键能力")
@MainActor
struct HotkeyTests {
    @Test("修饰键主键注入位表:功能位 + 设备相关位逐项正确")
    func modifierKeyMasksTable() {
        let expected: [Int: (mask: CGEventFlags, deviceBits: CGEventFlags)] = [
            54: (.maskCommand, CGEventFlags(rawValue: 0x10)),   // 右⌘ NX_DEVICERCMDKEYMASK
            55: (.maskCommand, CGEventFlags(rawValue: 0x08)),   // 左⌘ NX_DEVICELCMDKEYMASK
            56: (.maskShift, CGEventFlags(rawValue: 0x02)),     // 左⇧ NX_DEVICELSHIFTKEYMASK
            58: (.maskAlternate, CGEventFlags(rawValue: 0x20)), // 左⌥ NX_DEVICELALTKEYMASK
            59: (.maskControl, CGEventFlags(rawValue: 0x01)),   // 左⌃ NX_DEVICELCTLKEYMASK
            60: (.maskShift, CGEventFlags(rawValue: 0x04)),     // 右⇧ NX_DEVICERSHIFTKEYMASK
            61: (.maskAlternate, CGEventFlags(rawValue: 0x40)), // 右⌥ NX_DEVICERALTKEYMASK
            62: (.maskControl, CGEventFlags(rawValue: 0x2000)), // 右⌃ NX_DEVICERCTLKEYMASK
            63: (.maskSecondaryFn, []),                         // fn 仅功能位
        ]
        #expect(ActionExecutor.modifierKeyMasks.count == expected.count)
        for (keyCode, mask) in expected {
            let actual = ActionExecutor.modifierKeyMasks[keyCode]
            #expect(actual?.mask == mask.mask, "键码 \(keyCode) 功能位不符")
            #expect(actual?.deviceBits == mask.deviceBits, "键码 \(keyCode) 设备位不符")
        }
        // 普通键不在表内:走组合键路径(功能位来自 modifiers)
        #expect(ActionExecutor.modifierKeyMasks[0] == nil)
        #expect(ActionExecutor.modifierKeyMasks[122] == nil) // F1
    }

    @Test("录制判定表与注入位表覆盖同一组修饰键键码")
    func captureTableMatchesInjectionTable() {
        #expect(Set(HotkeySymbols.modifierMasksByKeyCode.keys)
                == Set(ActionExecutor.modifierKeyMasks.keys))
    }

    @Test("修饰键单键显示名")
    func modifierKeyNames() {
        #expect(HotkeySymbols.displayString(keyCode: 54, modifiers: []) == "右⌘")
        #expect(HotkeySymbols.displayString(keyCode: 61, modifiers: []) == "右⌥")
        #expect(HotkeySymbols.displayString(keyCode: 63, modifiers: []) == "fn")
        // 组合键显示不受新增条目影响
        #expect(HotkeySymbols.displayString(keyCode: 8, modifiers: ["command"]) == "⌘C")
    }

    @Test("单修饰键热键编解码往返稳定(右⌘ = hotkey(54, []))")
    func singleModifierHotkeyCodableRoundTrip() throws {
        let original = KeyAction.hotkey(keyCode: 54, modifiers: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyAction.self, from: data)
        #expect(decoded == original)
    }
}
