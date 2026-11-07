// MakeIcon — 生成 OpenDeck 的应用图标(1024px PNG)
// 视觉与应用一致:深色底座 + 3×3 彩色键帽 + 顶部光泽
// 用法:swift Scripts/MakeIcon.swift <输出.png>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

// 底座:深色圆角方形(macOS 图标网格圆角 ≈ 边长 22.5%)
let corner: CGFloat = 230
let inset: CGFloat = 100
let chassisRect = CGRect(x: inset, y: inset, width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2)
ctx.addPath(CGPath(roundedRect: chassisRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.clip()
ctx.drawLinearGradient(
    CGGradient(colorsSpace: space, colors: [color(0x2A2E36), color(0x17191D)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 0, y: CGFloat(side)), end: CGPoint(x: 0, y: 0), options: []
)

// 3×3 键帽(应用默认 Nord 调色板)
let palette: [UInt32] = [0xBF616A, 0xD08770, 0xEBCB8B, 0xA3BE8C, 0x88C0D0, 0x5E81AC, 0xB48EAD, 0x8FBCBB, 0x5E81AC]
let gridSide: CGFloat = 3
// 边缘留白必须 > 键间距:四角键帽要避开底座 230px 圆角弧(几何下限 52px,76px 留 34px 余量),否则被 clip 切角
let edgeMargin: CGFloat = 76
let cellGap: CGFloat = 44
let cellSize = (chassisRect.width - edgeMargin * 2 - cellGap * (gridSide - 1)) / gridSide
for index in 0..<9 {
    let row = CGFloat(index / 3)
    let column = CGFloat(index % 3)
    let x = chassisRect.minX + edgeMargin + column * (cellSize + cellGap)
    // CGContext y 轴朝上:图标视觉上行 0 在顶部
    let y = chassisRect.maxY - edgeMargin - (row + 1) * cellSize - row * cellGap
    let keyRect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
    let keyPath = CGPath(roundedRect: keyRect, cornerWidth: 52, cornerHeight: 52, transform: nil)

    ctx.saveGState()
    ctx.addPath(keyPath)
    ctx.clip()
    let top = color(palette[index]).lightened(by: 0.12)
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [top, color(palette[index])] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: 0, y: keyRect.maxY), end: CGPoint(x: 0, y: keyRect.minY), options: []
    )
    // 顶部光泽
    ctx.addPath(keyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.30), CGColor(gray: 1, alpha: 0.0)] as CFArray, locations: [0, 0.55])!,
        start: CGPoint(x: 0, y: keyRect.maxY), end: CGPoint(x: 0, y: keyRect.midY), options: []
    )
    ctx.restoreGState()
}

extension CGColor {
    func lightened(by amount: CGFloat) -> CGColor {
        let c = converted(to: space, intent: .defaultIntent, options: nil)!
        let components = c.components!
        return CGColor(
            srgbRed: min(1, components[0] + amount),
            green: min(1, components[1] + amount),
            blue: min(1, components[2] + amount),
            alpha: 1
        )
    }
}

let image = ctx.makeImage()!
let out = NSMutableData()
let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
try! out.write(to: URL(fileURLWithPath: output))
print("图标已生成:\(output)")
