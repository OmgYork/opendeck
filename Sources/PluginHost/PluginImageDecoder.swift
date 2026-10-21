import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// 插件 setImage 图像解码:data URL → CGImage。
/// 位图族(png/jpeg/gif/bmp/webp)走 ImageIO;SVG(百分号编码或 base64)经 NSImage
/// 栅格化到键面尺寸(官方 HTML 插件如 centeredclock 以 SVG 推表盘,每秒一帧)。
public enum PluginImageDecoder {
    public static func decodeCGImage(from dataURLString: String?, pixelSize: Int = 112) -> CGImage? {
        guard var payload = dataURLString, !payload.isEmpty else { return nil }
        var isSVG = false
        if payload.hasPrefix("data:") {
            guard let comma = payload.firstIndex(of: ",") else { return nil }
            let header = payload[..<comma].lowercased()
            if header.contains("svg") { isSVG = true }
            payload = String(payload[payload.index(after: comma)...])
        }
        if isSVG {
            return decodeSVG(payload, pixelSize: pixelSize)
        }
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// SVG 解码:体载两型——percent-encoded(utf8 文本)或 base64。NSImage 交 CoreSVG
    /// 栅格化;失败返回 nil(调用方回退 manifest 默认图),不抛
    private static func decodeSVG(_ payload: String, pixelSize: Int) -> CGImage? {
        let svgText: String?
        if payload.contains("%"), let decoded = payload.removingPercentEncoding {
            svgText = decoded
        } else if let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
                  let decoded = String(data: data, encoding: .utf8) {
            svgText = decoded
        } else {
            svgText = nil
        }
        guard let svgText, svgText.contains("<svg"),
              let svgData = svgText.data(using: .utf8),
              let image = NSImage(data: svgData)
        else { return nil }
        let side = max(16, pixelSize)
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
