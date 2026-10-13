import CoreGraphics
import Foundation
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

    @Test("软键尺寸 80")
    func softKeySize() {
        #expect(StreamDock293S.keySize(column: 4) == 100)
        #expect(StreamDock293S.keySize(column: 5) == 80)
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
}
