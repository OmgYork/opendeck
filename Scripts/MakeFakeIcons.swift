// MakeFakeIcons — 生成 FakePlugin.sdPlugin 的图像资源(一次性工具,产物已入库)
//
// 产出:
//   opendeck.fake.sdPlugin/images/off.png  (深蓝「待命」,manifest State 0 默认图)
//   opendeck.fake.sdPlugin/images/on.png   (绿「运行」,manifest State 1 默认图)
//   opendeck.fake.sdPlugin/plugin/generated.js (红色「插件」PNG 的 data URL,setImage 自定义图路径用)
//
// 用法:swift Scripts/MakeFakeIcons.swift

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func renderLabeled(red: CGFloat, green: CGFloat, blue: CGFloat, label: String, size: Int = 100) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    let square = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    ctx.fill(square)

    let font = CTFontCreateWithName("PingFang SC Semibold" as CFString, 26, nil)
    let attributes = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
    ] as CFDictionary
    guard let attributed = CFAttributedStringCreate(nil, label as CFString, attributes),
          let line = CTLineCreateWithAttributedString(attributed) as CTLine?
    else { return nil }
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.textPosition = CGPoint(x: (CGFloat(size) - textWidth) / 2, y: CGFloat(size) * 0.42)
    CTLineDraw(line, ctx)
    return ctx.makeImage()
}

func pngData(_ image: CGImage) -> Data? {
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
}

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pluginRoot = scriptDirectory.appendingPathComponent("opendeck.fake.sdPlugin")
try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("images"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("plugin"), withIntermediateDirectories: true)

guard let off = renderLabeled(red: 0.18, green: 0.20, blue: 0.25, label: "待命"),
      let on = renderLabeled(red: 0.30, green: 0.55, blue: 0.35, label: "运行"),
      let red = renderLabeled(red: 0.75, green: 0.25, blue: 0.25, label: "插件"),
      let offData = pngData(off),
      let onData = pngData(on),
      let redData = pngData(red)
else {
    print("❌ 渲染失败")
    exit(1)
}
try offData.write(to: pluginRoot.appendingPathComponent("images/off.png"))
try onData.write(to: pluginRoot.appendingPathComponent("images/on.png"))

let generated = """
// 本文件由 Scripts/MakeFakeIcons.swift 生成:红色「插件」PNG 的 data URL(setImage 自定义图路径用)
'use strict';
module.exports = "data:image/png;base64,\(redData.base64EncodedString())";
"""
try generated.write(to: pluginRoot.appendingPathComponent("plugin/generated.js"), atomically: true, encoding: .utf8)
print("✅ FakePlugin 资源已生成:\(pluginRoot.path)")
