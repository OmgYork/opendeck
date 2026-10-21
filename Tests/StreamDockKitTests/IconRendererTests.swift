import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import StreamDockKit

@Suite("IconRenderer")
struct IconRendererTests {
    @Test("渲染+JPEG 编码在设备限制内")
    func jpegUnderLimit() {
        for title in ["1", "HI", "快捷键", "一个很长的标题文字"] {
            guard let image = IconRenderer.render(size: 100, backgroundColorHex: "#5E81AC", title: title) else {
                Issue.record("渲染失败: \(title)")
                continue
            }
            #expect(image.width == 100 && image.height == 100)
            guard let jpeg = IconRenderer.jpeg(from: image) else {
                Issue.record("JPEG 编码失败: \(title)")
                continue
            }
            #expect(!jpeg.isEmpty)
            #expect(jpeg.count <= StreamDock293S.maxKeyJPEGBytes)
            // JPEG 魔数
            #expect(jpeg[jpeg.startIndex] == 0xFF)
            #expect(jpeg[jpeg.index(after: jpeg.startIndex)] == 0xD8)
        }
    }

    @Test("键面尺寸统一 112(官方 app 实测键面分辨率)")
    func keySize() {
        for column in 0..<StreamDock293S.columns {
            #expect(StreamDock293S.keySize(column: column) == 112)
        }
    }

    @Test("hex 颜色解析")
    func hexColor() {
        let red = HexColor.parse("#FF0000")
        #expect(red != nil)
        #expect(abs(red!.components![0] - 1) < 0.001)
        #expect(HexColor.parse("not-a-color") == nil)
        #expect(HexColor.parse("#12345") == nil)
    }

    @Test("旋转 90° 仍产出同尺寸图")
    func rotationKeepsSize() {
        let image = IconRenderer.render(size: 80, backgroundColorHex: "#BF616A", title: "S1", rotationDegrees: 90)
        #expect(image?.width == 80)
        #expect(image?.height == 80)
    }

    @Test("纯黑键面:JPEG 在限制内且解码后全黑(熄屏黑图)")
    func blackJPEG() throws {
        let side = 100
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let black = try #require(context.makeImage())

        let jpeg = try #require(IconRenderer.jpeg(from: black))
        #expect(jpeg.count <= StreamDock293S.maxKeyJPEGBytes)
        #expect(jpeg[jpeg.startIndex] == 0xFF)
        #expect(jpeg[jpeg.index(after: jpeg.startIndex)] == 0xD8)

        // 解码回位图逐像素验证:JPEG 有损,允许 ±2 量化噪声
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let sample = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(decoded, in: CGRect(x: 0, y: 0, width: side, height: side))
        let buffer = try #require(sample.data)
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var darkPixels = 0
        for i in 0..<(side * side)
        where pixels[i * 4] <= 2 && pixels[i * 4 + 1] <= 2 && pixels[i * 4 + 2] <= 2 {
            darkPixels += 1
        }
        #expect(darkPixels == side * side)
    }

    @Test("JPEG 超限降级:画布尺寸保持不变(防固件右下锚定偏移)")
    func jpegFallbackKeepsCanvasSize() throws {
        // 高细节噪声图:100×100 必然超过 10240B,触发 scale 降级路径
        let side = 100
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                         bytesPerRow: side * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for y in 0..<side {
            for x in 0..<side {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r = UInt8((seed >> 33) & 0xFF)
                let g = UInt8((seed >> 41) & 0xFF)
                let b = UInt8((seed >> 49) & 0xFF)
                ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                         blue: CGFloat(b) / 255, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let noisy = try #require(ctx.makeImage())
        let jpeg = try #require(IconRenderer.jpeg(from: noisy, maxBytes: 10240))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == side, "降级后画布宽度应保持 100,实得 \(decoded.width)")
        #expect(decoded.height == side, "降级后画布高度应保持 100,实得 \(decoded.height)")
    }
}
