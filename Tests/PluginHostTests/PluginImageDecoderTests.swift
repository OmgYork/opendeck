import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PluginHost

@Suite("PluginImageDecoder")
struct PluginImageDecoderTests {
    @Test("data URL 解码:与 CGImageDestination 编码往返")
    func decodeDataURL() {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            Issue.record("CGContext 创建失败")
            return
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        guard let image = ctx.makeImage() else { return }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        let dataURL = "data:image/png;base64,\((out as Data).base64EncodedString())"

        let decoded = PluginImageDecoder.decodeCGImage(from: dataURL)
        #expect(decoded?.width == 3)
        #expect(decoded?.height == 3)
    }

    @Test("SVG 两种载体的栅格化;空串/garbage/裸 base64 边界")
    func svgAndFallbacks() {
        // 有效 SVG(base64 与 percent-encoded 双载体)→ 栅格化为请求尺寸
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10' fill='red'/></svg>"
        let b64 = Data(svg.utf8).base64EncodedString()
        let percent = svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let decodedB64 = PluginImageDecoder.decodeCGImage(from: "data:image/svg+xml;base64,\(b64)", pixelSize: 50)
        #expect(decodedB64?.width == 50)
        let decodedPercent = PluginImageDecoder.decodeCGImage(from: "data:image/svg+xml;charset=utf8,\(percent)", pixelSize: 40)
        #expect(decodedPercent?.width == 40)
        // 无尺寸病态输入(<svg/>)由 NSImage 容忍为默认尺寸(透明图,叠瓷贴无害),不另设契约
        #expect(PluginImageDecoder.decodeCGImage(from: "data:image/png;base64,") == nil)
        #expect(PluginImageDecoder.decodeCGImage(from: "") == nil)
        #expect(PluginImageDecoder.decodeCGImage(from: nil) == nil)
        #expect(PluginImageDecoder.decodeCGImage(from: "not-a-data-url") == nil)
    }

    @Test("FakePlugin 夹具守护:manifest 可解析、两态、图片资源在盘")
    func fakePluginFixture() throws {
        let pluginRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Scripts/opendeck.fake.sdPlugin")
            .standardizedFileURL
        let manifest = try SDManifest.load(fromDirectory: pluginRoot)
        #expect(manifest.pluginUUID == "opendeck.fake")
        #expect(manifest.family.isNode)
        let action = try #require(manifest.keypadActions.first)
        #expect(action.stateCount == 2)
        for stateImage in action.stateImages {
            #expect(SDManifest.resolveImageURL(pluginRoot: pluginRoot, manifestPath: stateImage) != nil)
        }
        // 红图 data URL 可解码(generated.js 的 module.exports 是一行 data:image/png)
        let generated = try String(contentsOf: pluginRoot.appendingPathComponent("plugin/generated.js"), encoding: .utf8)
        guard let range = generated.range(of: "data:image/png;base64,") else {
            Issue.record("generated.js 缺 data URL")
            return
        }
        let dataURL = String(generated[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(PluginImageDecoder.decodeCGImage(from: dataURL) != nil)
    }
}
