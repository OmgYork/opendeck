import CoreGraphics
import Foundation
import ImageIO

/// 插件 setImage 图像解码:data URL(base64)→ CGImage。
/// M2 支持位图族(png/jpeg/gif/bmp/webp);SVG 明确返回 nil(调用方回退 manifest 默认图并记日志)。
public enum PluginImageDecoder {
    public static func decodeCGImage(from dataURLString: String?) -> CGImage? {
        guard var payload = dataURLString, !payload.isEmpty else { return nil }
        if payload.hasPrefix("data:") {
            guard let comma = payload.firstIndex(of: ",") else { return nil }
            let header = payload[..<comma].lowercased()
            if header.contains("svg") { return nil }
            payload = String(payload[payload.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
