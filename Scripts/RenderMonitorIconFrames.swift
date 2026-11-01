import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 渲染交付预览帧。与生产用同一个 MonitorInputIconRenderer,
// 因此预览里的每一帧就是设备上真实下发的位图(只是未做 180° 预旋转)。
// 用法: swiftc Sources/OpenDeck/HexCGColor.swift Sources/OpenDeck/MonitorInputIcon.swift \
//              Scripts/RenderMonitorIconFrames.swift -o RenderMonitorIconFrames
//       (HexCGColor.swift 必须一起编译:渲染器的 hex 解析已收敛到那一处,且它只依赖 CoreGraphics)
//       ./RenderMonitorIconFrames Design/MonitorInputIcon/frames

@main
enum RenderMonitorIconFrames {
    static func main() {
        let outputRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1
                             ? CommandLine.arguments[1]
                             : "Design/MonitorInputIcon/frames")
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        // 静息两态(大图看细节)
        for source in MonitorInputSource.allCases {
            render(.idle(source), size: 448, name: "idle-\(source.rawValue)-448", in: outputRoot)
            render(.idle(source), size: 112, name: "idle-\(source.rawValue)-112", in: outputRoot)
        }

        // 两个方向的完整切换序列
        for frame in 0..<MonitorIconTiming.transitionFrameCount {
            render(.transition(from: .mac, to: .pc, frame: frame, reverted: false),
                   size: 336, name: String(format: "m2p-%02d", frame), in: outputRoot)
            render(.transition(from: .pc, to: .mac, frame: frame, reverted: false),
                   size: 336, name: String(format: "p2m-%02d", frame), in: outputRoot)
            render(.transition(from: .mac, to: .pc, frame: frame, reverted: false),
                   size: 112, name: String(format: "m2p-%02d-112", frame), in: outputRoot)
        }

        // 静息呼吸(信号包):两个源各一组,方向随当前输入源
        for source in MonitorInputSource.allCases {
            for frame in 0..<MonitorIconTiming.ambientFrameCount {
                render(.ambient(source, frame: frame), size: 336,
                       name: "ambient-\(source.rawValue)-\(String(format: "%02d", frame))", in: outputRoot)
            }
        }

        writeContactSheet(in: outputRoot)
        print("完成 → \(outputRoot.path)")
    }

    private static func render(_ frame: MonitorIconFrame, size: Int, name: String, in root: URL) {
        guard let image = MonitorInputIconRenderer.image(size: size, frame: frame, prerotated: false) else {
            print("✗ 渲染失败 \(name)")
            return
        }
        writePNG(image, named: name, in: root)
    }

    private static func writePNG(_ image: CGImage, named name: String, in root: URL) {
        let url = root.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            print("✗ 无法创建 \(url.path)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            print("✓ \(url.lastPathComponent)")
        }
    }

    /// 4×3 接触表:一屏看完整条 12 帧时间轴
    private static func writeContactSheet(in root: URL) {
        let cell: CGFloat = 336
        let gutter: CGFloat = 12
        let columns = 4
        let rows = 3
        let width = CGFloat(columns) * cell + CGFloat(columns + 1) * gutter
        let height = CGFloat(rows) * cell + CGFloat(rows + 1) * gutter
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                                  bitsPerComponent: 8, bytesPerRow: Int(width) * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.setFillColor(CGColor(srgbRed: 0.035, green: 0.043, blue: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for frame in 0..<MonitorIconTiming.transitionFrameCount {
            guard let image = MonitorInputIconRenderer.image(
                size: 336, frame: .transition(from: .mac, to: .pc, frame: frame, reverted: false),
                prerotated: false
            ) else { continue }
            let column = frame % columns
            let row = frame / columns
            let x = gutter + CGFloat(column) * (cell + gutter)
            let y = height - gutter - cell - CGFloat(row) * (cell + gutter)
            ctx.draw(image, in: CGRect(x: x, y: y, width: cell, height: cell))
        }
        if let sheet = ctx.makeImage() {
            writePNG(sheet, named: "contact-sheet-12f", in: root)
        }
    }
}
