import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 键面图渲染:背景色 + 可选底图(铺满)+ 居中标题 → CGImage → JPEG(自动压到设备限制内)。
public enum IconRenderer {
    /// 画一张键面图。
    /// - Parameters:
    ///   - size: 键面边长(293S:主键 100,软键 80)
    ///   - backgroundColorHex: "#RRGGBB" 或 "#RRGGBBAA"
    ///   - title: 居中标题(支持中文)
    ///   - iconPath: 可选底图路径(按比例铺满居中裁切)
    ///   - rotationDegrees: 整图旋转(设备 LCD 若横向安装,传 90/270 校正)
    public static func render(
        size: Int,
        backgroundColorHex: String,
        title: String?,
        iconPath: String? = nil,
        rotationDegrees: Int = 0
    ) -> CGImage? {
        guard size > 0 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let square = CGSize(width: size, height: size)
        if rotationDegrees != 0 {
            ctx.translateBy(x: square.width / 2, y: square.height / 2)
            ctx.rotate(by: CGFloat(rotationDegrees) * .pi / 180)
            ctx.translateBy(x: -square.width / 2, y: -square.height / 2)
        }

        let background = HexColor.parse(backgroundColorHex) ?? CGColor(srgbRed: 0.23, green: 0.26, blue: 0.35, alpha: 1)
        ctx.setFillColor(background)
        ctx.fill(CGRect(origin: .zero, size: square))

        if let iconPath, let icon = loadImage(at: iconPath) {
            drawAspectFill(icon, in: ctx, square: square)
        }
        if let title, !title.isEmpty {
            drawTitle(title, in: ctx, square: square, on: background)
        }
        return ctx.makeImage()
    }

    /// CGImage → JPEG:质量 0.9 起步循环下调,仍超限则整体缩放后重试。
    public static func jpeg(from image: CGImage, maxBytes: Int = StreamDock293S.maxKeyJPEGBytes) -> Data? {
        var current = image
        for scale in [1.0, 0.8, 0.6] {
            if scale < 1.0, let scaled = redraw(image, scale: scale) {
                current = scaled
            }
            var quality = 0.9
            while quality >= 0.1 {
                if let data = encode(current, quality: quality), data.count <= maxBytes {
                    return data
                }
                quality -= 0.15
            }
        }
        return encode(current, quality: 0.1)
    }

    // MARK: - 私有

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func redraw(_ image: CGImage, scale: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func loadImage(at path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func drawAspectFill(_ image: CGImage, in ctx: CGContext, square: CGSize) {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scale = max(square.width / imageWidth, square.height / imageHeight)
        let drawSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let origin = CGPoint(
            x: (square.width - drawSize.width) / 2,
            y: (square.height - drawSize.height) / 2
        )
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: origin, size: drawSize))
    }

    private static func drawTitle(_ title: String, in ctx: CGContext, square: CGSize, on background: CGColor) {
        let fontSize = square.width * fontSizeFactor(forCount: title.count)
        let font = CTFontCreateWithName("PingFang SC Semibold" as CFString, fontSize, nil)
        let isLight = isLightColor(background)
        let color = isLight ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, title as CFString, attributes as CFDictionary),
              let line = CTLineCreateWithAttributedString(attributed) as CTLine?
        else { return }

        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let textHeight = fontSize * 1.1
        // 位图上下文 y 轴朝下,翻转文字
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(
            x: max(4, (square.width - width) / 2),
            y: square.height / 2 + textHeight / 2 - fontSize * 0.16
        )
        CTLineDraw(line, ctx)
        ctx.textMatrix = .identity
    }

    private static func fontSizeFactor(forCount count: Int) -> CGFloat {
        switch count {
        case ...2: 0.34
        case ...4: 0.24
        case ...6: 0.17
        default: 0.13
        }
    }

    private static func isLightColor(_ color: CGColor) -> Bool {
        guard let components = color.components, components.count >= 3 else { return false }
        let luminance = 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
        return luminance > 0.6
    }
}

enum HexColor {
    /// 解析 "#RRGGBB" / "#RRGGBBAA" / "RRGGBB"(CGColor 是 CF 类型,不能加 convenience init)
    static func parse(_ hex: String) -> CGColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard (6...8).contains(value.count), let raw = UInt64(value, radix: 16) else { return nil }
        let r, g, b, a: UInt64
        if value.count == 8 {
            (r, g, b, a) = ((raw >> 24) & 0xff, (raw >> 16) & 0xff, (raw >> 8) & 0xff, raw & 0xff)
        } else {
            (r, g, b, a) = ((raw >> 16) & 0xff, (raw >> 8) & 0xff, raw & 0xff, 0xff)
        }
        return CGColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
