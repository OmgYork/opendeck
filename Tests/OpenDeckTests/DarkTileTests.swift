import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OpenDeck

/// 「暗夜仪表」(§6.33):温色映射/弧分率/扫摆帧/睡眠锁状态渲染的契约。
/// 视觉美感由真机与截图验收;这里钉住映射与动画的数学。
@MainActor
@Suite("暗夜仪表瓷贴")
struct DarkTileTests {
    @Test("温度弧色:低温绿 / 中段琥珀 / 高温红,连续插值无跳变")
    func tempColorMapping() {
        let cool = DarkTileStyle.tempColor(45)
        let warm = DarkTileStyle.tempColor(60)
        let hot = DarkTileStyle.tempColor(85)
        #expect(cool == DarkTileStyle.cpuAccent)
        #expect(warm != cool && warm != DarkTileStyle.red, "中段应为绿→琥珀插值")
        #expect(hot.components![0] > warm.components![0], "红通道随温度上升")
    }

    @Test("弧分率:百分比/100,温度映射 35–90°,双端钳制")
    func fractionMapping() {
        #expect(StatTileRenderer.fraction(kind: .cpu, celsiusOrPercent: 100) == 1)
        #expect(StatTileRenderer.fraction(kind: .gpu, celsiusOrPercent: 87) == 0.87)
        #expect(StatTileRenderer.fraction(kind: .temp, celsiusOrPercent: 35) == 0)
        #expect(StatTileRenderer.fraction(kind: .temp, celsiusOrPercent: 90) == 1)
        #expect(StatTileRenderer.fraction(kind: .temp, celsiusOrPercent: 150) == 1, "越界钳制")
        #expect(StatTileRenderer.fraction(kind: .temp, celsiusOrPercent: 10) == 0)
    }

    @Test("扫摆帧:6 帧递进,首尾分率单调")
    func sweepFrames() throws {
        let frames = StatTileRenderer.sweepFrames(kind: .cpu, fromFraction: 0.2, toFraction: 0.9, value: "90%")
        #expect(frames.count == 6)
        #expect(frames.allSatisfy { $0.width == 112 })
    }

    /// 性能守卫(§6.35 实测回归):利用率逐样本微动必须直接换帧,不得逐轮扫摆
    @Test("扫摆阈值:微动(<0.10)不扫,大跳(≥0.10)扫")
    func sweepThresholdGuard() {
        // 微动 0.03:不扫
        #expect(abs(0.53 - 0.50) < StatTileAnimator.sweepThreshold)
        // 大跳 0.37:扫
        #expect(abs(0.87 - 0.50) >= StatTileAnimator.sweepThreshold)
        #expect(StatTileAnimator.sweepThreshold == 0.10)
    }

    @Test("睡眠锁渲染:三态产物互异且尺寸正确")
    func sleepGuardStates() throws {
        let on = try #require(SleepGuardTileRenderer.image(state: .on))
        let off = try #require(SleepGuardTileRenderer.image(state: .off))
        let warn = try #require(SleepGuardTileRenderer.image(state: .unauthorized))
        #expect(on.width == 112)
        #expect(!Self.sameImage(on, off))
        #expect(!Self.sameImage(on, warn))
    }

    @Test("锁扣过渡帧:ON↔OFF 8 帧,涉 unauthorized 返回 nil(直接换帧)")
    func lockTransition() {
        #expect(SleepGuardTileRenderer.transitionFrames(from: .on, to: .off)?.count == 8)
        #expect(SleepGuardTileRenderer.transitionFrames(from: .off, to: .on)?.count == 8)
        #expect(SleepGuardTileRenderer.transitionFrames(from: .on, to: .unauthorized) == nil)
        #expect(SleepGuardTileRenderer.transitionFrames(from: .on, to: .on) == nil)
    }

    @Test("媒体徽章:六种全部可渲染,尺寸 112")
    func mediaVariants() throws {
        for kind in ["playPause", "next", "previous", "volumeUp", "volumeDown", "mute"] {
            let image = try #require(MediaTileRenderer.image(kind: kind))
            #expect(image.width == 112 && image.height == 112)
        }
    }

    private static func sameImage(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let ctxA = CGContext(data: nil, width: a.width, height: a.height, bitsPerComponent: 8,
                                   bytesPerRow: a.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let ctxB = CGContext(data: nil, width: b.width, height: b.height, bitsPerComponent: 8,
                                   bytesPerRow: b.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        func bytes(_ image: CGImage?) -> Data? {
            guard let image, let provider = image.dataProvider, let data = provider.data else { return nil }
            return data as Data
        }
        return bytes(ctxA.makeImage()) == bytes(ctxB.makeImage())
    }
}

extension DarkTileTests {
    /// 采样探针:连续两次 sample,第二次 CPU 差分必须出值(---"-" 持续 = 采样链断)
    @Test("StatSampler 连续采样:第二次 CPU 出值")
    func samplerProducesCPUDelta() async throws {
        let sampler = StatSampler()
        _ = sampler.sample() // 首采建基线
        // 差分窗口要盖过 mach tick 粒度:120ms 偶发 totalDelta=0(测试化)
        try await Task.sleep(for: .milliseconds(500))
        let second = sampler.sample()
        #expect(second.cpu != nil, "第二次采样 CPU 应出值,实际 \(String(describing: second.cpu))")
    }
}

extension DarkTileTests {
    /// 导航卡尺(§6.34):静息/过渡帧契约
    @Test("NavTile:场景/页静息帧互异;从 action 识别 Kind")
    func navRestFrames() throws {
        let scene = try #require(NavTileRenderer.image(kind: .scene))
        let page = try #require(NavTileRenderer.image(kind: .page))
        #expect(scene.width == 112)
        #expect(!Self.sameImage(scene, page))
        #expect(NavTileRenderer.Kind(action: .nextScene) == .scene)
        #expect(NavTileRenderer.Kind(action: .previousPage) == .page)
        #expect(NavTileRenderer.Kind(action: .gotoPage(pageID: UUID())) == nil, "gotoPage 走既有路径,不入导航卡尺")
        #expect(NavTileRenderer.Kind(action: nil) == nil)
    }

    @Test("NavTile 过渡帧:方向非零 6 帧,零方向拒绝")
    func navTransitionFrames() {
        #expect(NavTileRenderer.transitionFrames(kind: .scene, offset: 1)?.count == 6)
        #expect(NavTileRenderer.transitionFrames(kind: .page, offset: -1, pageCount: 3, fromIndex: 1)?.count == 6)
        #expect(NavTileRenderer.transitionFrames(kind: .page, offset: 0) == nil)
    }

    /// 页点跟随真实页位(§6.34 用户反馈修复):不同当前页渲染互异;
    /// 过渡帧辉光滑移(中段位介于起讫);单页场景单点
    @Test("页点跟随页位:不同页互异,过渡辉光滑移,单页单点")
    func pageDotsTrackState() throws {
        let page0 = try #require(NavTileRenderer.image(kind: .page, pageCount: 3, pageIndex: 0))
        let page1 = try #require(NavTileRenderer.image(kind: .page, pageCount: 3, pageIndex: 1))
        let page2 = try #require(NavTileRenderer.image(kind: .page, pageCount: 3, pageIndex: 2))
        #expect(!Self.sameImage(page0, page1))
        #expect(!Self.sameImage(page1, page2))
        // 单页:唯一辉光点
        let single = try #require(NavTileRenderer.image(kind: .page, pageCount: 1, pageIndex: 0))
        #expect(!Self.sameImage(single, page0))
        // 过渡中段帧:辉光位于起讫之间(与两端静息帧都不同)
        let mid = try #require(try #require(NavTileRenderer.transitionFrames(kind: .page, offset: 1,
                                                                            pageCount: 3, fromIndex: 0))[2])
        #expect(!Self.sameImage(mid, page0))
        #expect(!Self.sameImage(mid, page1))
    }
}
