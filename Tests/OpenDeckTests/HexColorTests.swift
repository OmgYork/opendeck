import SwiftUI
import Testing

@testable import OpenDeck

/// hex 解析唯一实现(HexCGColor)的契约 + KeyPalette 委托后的行为守卫。
/// 回归背景:KeyPalette 曾有独立解析,对 7 位输入产出错位色而非兜底灰
/// (两份实现漂移的实证)——「7 位返回 nil」这条守卫防的是再抄回去。
@Suite("hex 解析与键帽配色")
@MainActor
struct HexColorTests {
    @Test("6/8 位解析正确,alpha 缺省为 1")
    func basicParsing() {
        let c = HexCGColor.components("#4DA3FF")
        #expect(c != nil)
        #expect(abs(c!.r - Double(0x4D) / 255) < 0.0001)
        #expect(abs(c!.g - Double(0xA3) / 255) < 0.0001)
        #expect(abs(c!.b - Double(0xFF) / 255) < 0.0001)
        #expect(c!.a == 1)
        let withAlpha = HexCGColor.components("12345678") // 无 # 前缀也合法
        #expect(withAlpha != nil)
        #expect(abs(withAlpha!.a - Double(0x78) / 255) < 0.0001)
    }

    @Test("7 位等非法输入返回 nil(漂移守卫)")
    func malformedReturnsNil() {
        for hex in ["#1234567", "1234567", "", "#", "##123456", "#12345", "#123456789", "zzzzzz"] {
            #expect(HexCGColor.components(hex) == nil, "非法输入 \(hex) 竟被解析")
        }
    }

    @Test("parse/opaque 产出 sRGB CGColor 且不透明")
    func parseAndOpaque() {
        let cg = HexCGColor.parse("#FF0000")
        #expect(cg != nil)
        #expect(cg?.alpha == 1)
        let opaque = HexCGColor.opaque("#11223344")
        #expect(opaque?.alpha == 1, "opaque 应抹掉 alpha")
    }

    @Test("KeyPalette 委托后行为不变:合法色/兜底灰/亮度阈值")
    func keyPaletteBehavior() {
        let white = KeyPalette(hex: "#FFFFFF")
        #expect(white.isLight, "纯白应判浅色")
        #expect(white.textColor == Color(white: 0.08))

        let black = KeyPalette(hex: "#000000")
        #expect(!black.isLight)
        #expect(black.textColor == .white)

        // 漂移守卫:7 位输入应走兜底灰,而不是产出错位色
        let fallback = KeyPalette(hex: "#1234567")
        #expect(fallback.color == Color(white: 0.25))
        #expect(!fallback.isLight)
    }
}
