import AppKit
import SwiftUI

// MARK: - 全局热键捕获(编辑 sheet 用)

// 自 EditorView.swift 拆出(2026-11-01 瘦身):NSEvent 本地监听的录制引擎与捕获输入框。

/// keyCode/修饰键 ↔ 显示符号、配置字符串的转换(按美式 ANSI 布局)
enum HotkeySymbols {
    private static let keyNames: [Int: String] = [
        // 字母区(kVK_ANSI_A…Z 扫描码不连续)
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        // 数字行与符号
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".",
        // 常用功能键
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 117: "⌦",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        118: "F4", 119: "End", 120: "F2", 122: "F1",
        115: "Home", 116: "PageUp", 121: "PageDown",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // 修饰键(kVK_RightCommand…kVK_Function):可单独绑定为热键主键(如右⌘触发器)
        54: "右⌘", 55: "左⌘", 56: "左⇧", 58: "左⌥", 59: "左⌃",
        60: "右⇧", 61: "右⌥", 62: "右⌃", 63: "fn",
    ]

    /// 修饰键键码 → modifierFlags 里的功能位(左右同位)。
    /// flagsChanged 事件的 keyCode 指明是哪颗物理键,该位在 modifierFlags 里置位 = 按下。
    /// 大写锁定(57)等锁存键不在表内,不参与单键录制。
    static let modifierMasksByKeyCode: [Int: NSEvent.ModifierFlags] = [
        54: .command, 55: .command,
        56: .shift, 60: .shift,
        58: .option, 61: .option,
        59: .control, 62: .control,
        63: .function,
    ]

    static func displayString(keyCode: Int, modifiers: [String]) -> String {
        modifierSymbols(modifiers) + (keyNames[keyCode] ?? "Key(\(keyCode))")
    }

    /// 已存配置的修饰键 → 展示符号,顺序遵循 macOS 惯例 ⌃⌥⇧⌘
    static func modifierSymbols(_ modifiers: [String]) -> String {
        var out = ""
        if modifiers.contains("control") { out += "⌃" }
        if modifiers.contains("option") { out += "⌥" }
        if modifiers.contains("shift") { out += "⇧" }
        if modifiers.contains("command") { out += "⌘" }
        return out
    }

    /// 录制中按住修饰键时的实时预览
    static func modifierPreview(for flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    /// NSEvent 修饰键 → 配置层字符串(契约取值:command/option/control/shift)
    static func configModifiers(for flags: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if flags.contains(.command) { out.append("command") }
        if flags.contains(.option) { out.append("option") }
        if flags.contains(.control) { out.append("control") }
        if flags.contains(.shift) { out.append("shift") }
        return out
    }
}

struct HotkeyCaptureField: View {
    @Binding var keyCode: Int?
    @Binding var modifiers: [String]

    @State private var monitor = HotkeyCaptureMonitor()
    @State private var recording = false
    @State private var livePreview = ""

    var body: some View {
        HStack(spacing: 8) {
            display
            Spacer()
            if recording {
                Button("取消") { stopRecording() }
            } else {
                Button(keyCode == nil ? "录制" : "重新录制") { startRecording() }
            }
            if keyCode != nil, !recording {
                Button {
                    keyCode = nil
                    modifiers = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除组合键")
            }
        }
        .onDisappear {
            monitor.end()
            recording = false
        }
    }

    @ViewBuilder
    private var display: some View {
        if recording {
            Label(
                livePreview.isEmpty ? "按下组合键,或单独按下再松开修饰键;⎋ 取消" : "\(livePreview) … 松开修饰键即录制",
                systemImage: "record.circle"
            )
            .foregroundStyle(.orange)
        } else if let code = keyCode {
            Text(HotkeySymbols.displayString(keyCode: code, modifiers: modifiers))
                .font(.system(.body, design: .monospaced).weight(.medium))
        } else {
            Text("未设置").foregroundStyle(.secondary)
        }
    }

    private func startRecording() {
        livePreview = ""
        recording = true
        monitor.onCapture = { code, mods in
            keyCode = code
            modifiers = mods
            recording = false
        }
        monitor.onCancel = { recording = false }
        monitor.onModifiersChanged = { preview in
            livePreview = preview
        }
        monitor.start()
    }

    private func stopRecording() {
        monitor.end()
        recording = false
        livePreview = ""
    }
}

final class HotkeyCaptureMonitor {
    private var token: Any?

    /// solo 候选:已按下、尚未伴随主键或其他修饰键的修饰键码(单按修饰键录制的判定状态)
    private var soloModifiers: Set<Int> = []
    /// 本轮出现过第二个修饰键或任何主键:之后的修饰键「按下再松开」不再视为单键录制
    private var soloSequenceBroken = false

    var onCapture: ((Int, [String]) -> Void)?
    var onCancel: (() -> Void)?
    var onModifiersChanged: ((String) -> Void)?

    func start() {
        end()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func end() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
        soloModifiers = []
        soloSequenceBroken = false
    }

    /// 返回 nil 表示吞掉该事件(录制期间按键不应再触发输入框/快捷键)
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            onModifiersChanged?(HotkeySymbols.modifierPreview(for: event.modifierFlags))
            trackSoloModifier(event)
            return nil
        case .keyDown:
            // ⎋ 语义 = 取消录制:⎋ 本身几乎不会被设为热键,还能避免顺带关闭 Sheet
            if event.keyCode == 53 {
                end()
                onCancel?()
                return nil
            }
            let modifiers = HotkeySymbols.configModifiers(for: event.modifierFlags)
            end()
            onCapture?(Int(event.keyCode), modifiers)
            return nil
        default:
            return event
        }
    }

    /// 单按修饰键录制:修饰键「单独按下 → 松开」(期间无任何主键、无第二个修饰键)
    /// 即录制为该键本身(如右⌘ = hotkey(54, []),让槽位可以模拟单颗修饰键)。
    /// 修饰键按下/抬起只有 flagsChanged 事件:keyCode 指明是哪颗键,
    /// 该键的功能位在 modifierFlags 里置位 = 按下、清位 = 松开。
    private func trackSoloModifier(_ event: NSEvent) {
        let code = Int(event.keyCode)
        guard let mask = HotkeySymbols.modifierMasksByKeyCode[code] else { return } // 非修饰键(如大写锁定)不参与
        if event.modifierFlags.contains(mask) {
            if !soloModifiers.isEmpty { soloSequenceBroken = true } // 组合键积累中,不是单按
            soloModifiers.insert(code)
        } else {
            // 松开时恰好是全程单独按住的这一颗 → 录制为单键
            if soloModifiers == [code], !soloSequenceBroken {
                end()
                onCapture?(code, [])
                return
            }
            soloModifiers.remove(code)
            if soloModifiers.isEmpty { soloSequenceBroken = false } // 全部松开,下一轮重新判定
        }
    }
}

