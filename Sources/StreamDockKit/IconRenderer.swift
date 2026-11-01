import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 键面图渲染:背景色 + 可选底图(铺满)+ 居中标题 → CGImage → JPEG(自动压到设备限制内)。
public enum IconRenderer {
    /// 画一张键面图。
    /// - Parameters:
    ///   - size: 键面边长(293V3:112,官方 app 实测)
    ///   - backgroundColorHex: "#RRGGBB" 或 "#RRGGBBAA"
    ///   - title: 居中标题(支持中文)
    ///   - iconPath: 可选底图路径(按比例铺满居中裁切)
    ///   - rotationDegrees: 整图旋转,默认取设备型号的显示校正角(设备以 180° 旋转显示)
    public static func render(
        size: Int,
        backgroundColorHex: String,
        title: String?,
        iconPath: String? = nil,
        symbolName: String? = nil,
        rotationDegrees: Int = StreamDock293S.displayRotationDegrees
    ) -> CGImage? {
        let icon = iconPath.flatMap { loadImage(at: $0) }
        return render(size: size, backgroundColorHex: backgroundColorHex, title: title,
                      baseImage: icon, symbolName: symbolName, rotationDegrees: rotationDegrees)
    }

    /// 插件图像路径:现成位图(setImage 解码产物)作底图 + 可选标题 → 预旋转输出。
    /// 与 iconPath 变体同一条合成管线,保证设备上方向/排版一致。
    public static func render(
        size: Int,
        backgroundColorHex: String,
        title: String?,
        baseImage: CGImage?,
        symbolName: String? = nil,
        rotationDegrees: Int = StreamDock293S.displayRotationDegrees
    ) -> CGImage? {
        guard let upright = composeUpright(
            size: size, backgroundColorHex: backgroundColorHex, title: title,
            icon: baseImage, symbolName: symbolName
        ) else { return nil }
        // 设备以 180° 旋转显示,预旋转输出;图与文同源同变换,方向恒一致
        return rotated(upright, byDegrees: rotationDegrees)
    }

    /// 在正立空间合成键面(identity CTM、identity textMatrix——文字天然正立)
    private static func composeUpright(
        size: Int, backgroundColorHex: String, title: String?, icon: CGImage?, symbolName: String?
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

        let square = CGRect(x: 0, y: 0, width: size, height: size)
        let background = HexColor.parse(backgroundColorHex) ?? CGColor(srgbRed: 0.23, green: 0.26, blue: 0.35, alpha: 1)
        ctx.setFillColor(background)
        ctx.fill(square)

        if let icon {
            drawAspectFill(icon, in: ctx, square: square.size)
        } else if let symbolName, let symbol = symbolImage(named: symbolName, canvas: square.size) {
            // 默认图标:无底图时用 SF Symbol 作主视觉(与编辑器 KeycapView 的默认图标同语义)
            drawSymbol(symbol, in: ctx, square: square.size)
        }
        if let title, !title.isEmpty {
            drawTitle(title, in: ctx, square: square.size, on: background)
        }
        return ctx.makeImage()
    }

    /// 整图旋转(方形图无裁切问题)
    private static func rotated(_ image: CGImage, byDegrees degrees: Int) -> CGImage? {
        guard degrees != 0 else { return image }
        let side = max(image.width, image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.rotate(by: CGFloat(degrees) * .pi / 180)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    /// CGImage → JPEG:质量 0.9 起步循环下调,仍超限则整体缩放后重试。
    /// 起点用上一张成功图的质量:键面帧尺寸/复杂度稳定时一步命中,
    /// 每帧省掉逐档下调的重复全图编码。进程内调用方全在 MainActor
    /// (DeviceController);StreamDeckHarness 是独立可执行进程,不共享。
    // nonisolated(unsafe) 前提:render 的全部调用方都在主线程(设备/UI 同源),无并发写。
    // 若渲染移出主线程,先给这个变量上锁
    private nonisolated(unsafe) static var lastGoodQuality: Double = 0.9

    public static func jpeg(from image: CGImage, maxBytes: Int = StreamDock293S.maxKeyJPEGBytes) -> Data? {
        var current = image
        for scale in [1.0, 0.8, 0.6] {
            if scale < 1.0, let shrunk = redraw(image, scale: scale),
               let restored = expand(shrunk, toWidth: image.width, height: image.height) {
                // 缩小只为降细节省字节,画布必须还原原尺寸:小于键面的图会被固件锚在
                // 右下角显示,呈现「左/上空隙大」的偏移(2026-10-18 用户实测定位)
                current = restored
            }
            var quality = min(0.9, max(0.1, Self.lastGoodQuality))
            while quality >= 0.1 {
                if let data = encode(current, quality: quality), data.count <= maxBytes {
                    Self.lastGoodQuality = quality
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

    /// 把低分辨率图放大回指定画布(双线性):细节已丢失,字节量级保持省,但尺寸与键面一致
    private static func expand(_ image: CGImage, toWidth width: Int, height: Int) -> CGImage? {
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
        // CG 位图 y 轴朝上:键面底部 = 小 y,字形自基线向上生长;textMatrix 保持 identity
        // (竖翻 Mᵥ 是此前文字颠倒的根因——它会叠加在 CTM 之上,与预旋转合成出错误方向)
        ctx.textPosition = CGPoint(
            x: max(4, (square.width - width) / 2),
            y: square.height * 0.08
        )
        CTLineDraw(line, ctx)
    }

    /// SF Symbol → 白色 CGImage(按画布尺寸取点大小;用 AppKit 的 paletteColors 上色)
    private static func symbolImage(named name: String, canvas: CGSize) -> CGImage? {
        let pointSize = canvas.width * 0.5
        let base = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let tinted = base.applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(tinted) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 居中略上移绘制(底部留给标题)
    private static func drawSymbol(_ image: CGImage, in ctx: CGContext, square: CGSize) {
        let maxSide = square.width * 0.54
        let scale = min(maxSide / CGFloat(image.width), maxSide / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(
            x: (square.width - size.width) / 2,
            y: (square.height - size.height) / 2 + square.height * 0.06
        )
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: origin, size: size))
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
