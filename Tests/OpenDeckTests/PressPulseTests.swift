import CoreGraphics
import Foundation
import Testing
@testable import OpenDeck

/// 按压脉冲(§6.32):帧生成纯函数与新动效枚举的契约。
/// 视觉手感(闪亮+微放大)由真机按压验收;这里钉住「静息零成本」与「进度边界」。
@MainActor
@Suite("PressPulse 按压脉冲")
struct PressPulseTests {
    private func makeBase() -> CGImage? {
        let side = 112
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    @Test("帧边界:progress 0/越界回原图,中段产出同尺寸新帧")
    func frameBoundaries() throws {
        let base = try #require(makeBase())
        // 静息/越界:原样返回(零成本路径)
        #expect(DesignTraits.sameImage(PressPulseAnimator.pulseImage(base: base, progress: 0), base))
        #expect(DesignTraits.sameImage(PressPulseAnimator.pulseImage(base: base, progress: 1.0), base))
        #expect(DesignTraits.sameImage(PressPulseAnimator.pulseImage(base: base, progress: -0.5), base))
        // 中段:新帧,尺寸不变(固件锚定铁律)
        let mid = try #require(PressPulseAnimator.pulseImage(base: base, progress: 0.3))
        #expect(mid.width == base.width && mid.height == base.height)
        #expect(!DesignTraits.sameImage(mid, base), "脉冲中段应与基帧不同(有闪光叠加)")
    }

    @Test("帧序列:8 帧会话首尾收敛回基帧形态")
    func frameSequenceConverges() throws {
        let base = try #require(makeBase())
        let last = try #require(PressPulseAnimator.pulseImage(
            base: base, progress: Double(PressPulseAnimator.frameCount - 1) / Double(PressPulseAnimator.frameCount)
        ))
        // 尾帧闪光 alpha ≈ 0.45·(1/8)^1.5 ≈ 0.02,视觉上已收敛;真正的静息由 advance 的
        // 收尾分支直接回 base(不走 pulseImage),此处只验证尾帧与首帧不同(闪光在衰减)
        let first = try #require(PressPulseAnimator.pulseImage(base: base, progress: 0.05))
        #expect(!DesignTraits.sameImage(first, last), "闪光应随进度衰减")
    }

    @Test("新动效枚举:pressPulse 编解码往返 + CaseIterable 完整")
    func animationEnumRoundTrip() throws {
        let key = KeyConfig(title: "x", animation: .pressPulse)
        let data = try JSONEncoder().encode(key)
        let back = try JSONDecoder().decode(KeyConfig.self, from: data)
        #expect(back.animation == .pressPulse)
        #expect(Set(KeyAnimation.allCases) == [.monitorInput, .pressPulse, .picModeToggle])
    }
}

/// 图像等价判定(按 RGB 字节;单独小工具避免污染生产代码)
private enum DesignTraits {
    static func sameImage(_ a: CGImage?, _ b: CGImage?) -> Bool {
        guard let a, let b, a.width == b.width, a.height == b.height else { return false }
        guard let ctxA = CGContext(data: nil, width: a.width, height: a.height, bitsPerComponent: 8,
                                   bytesPerRow: a.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let ctxB = CGContext(data: nil, width: b.width, height: b.height, bitsPerComponent: 8,
                                   bytesPerRow: b.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        return bytes(ctxA.makeImage()) == bytes(ctxB.makeImage())
    }

    private static func bytes(_ image: CGImage?) -> Data? {
        guard let image, let provider = image.dataProvider, let data = provider.data else { return nil }
        return data as Data
    }
}
