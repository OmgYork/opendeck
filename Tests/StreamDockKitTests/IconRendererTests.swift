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

    @Test("键面尺寸统一 100")
    func keySize() {
        for column in 0..<StreamDock293S.columns {
            #expect(StreamDock293S.keySize(column: column) == 100)
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
}
