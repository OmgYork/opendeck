import Foundation

/// .sdPlugin 插件的 manifest.json 解析(宽容:字段缺失不崩,坏 action 跳过)。
/// 插件分两家族:Node(CodePath 为 .js,由本机 node 拉起,M2 支持)与 HTML(CodePath 为
/// .html,WebView 承载,M3+);manifest 图片路径普遍无扩展名,需按候选探测。
public struct SDManifest: Sendable, Equatable {
    public enum Family: Sendable, Equatable {
        /// Node 插件,可由宿主拉起;关联值 = manifest 要求的 node 大版本("20" 等,可能缺)
        case node(String?)
        /// HTML 插件,宿主以隐藏 WKWebView 承载(M3-2 起支持)
        case html
        /// CodePath 缺失/无法识别
        case unsupported

        public var isNode: Bool {
            if case .node = self { return true }
            return false
        }

        /// 可被宿主承载:Node(子进程)或 HTML(WebView)
        public var isHostable: Bool {
            switch self {
            case .node, .html: return true
            case .unsupported: return false
            }
        }
    }

    public struct Action: Sendable, Equatable {
        public let uuid: String
        public let name: String
        /// 每个 state 的 manifest 图路径原文(可能无扩展名或缺失)
        public let stateImages: [String?]
        public let disableAutomaticStates: Bool
        public let propertyInspectorPath: String?
        /// Controllers 缺省或空数组 = 不限制(官方 OBS 插件即空数组);仅当显式列出且不含
        /// "Keypad"(如 ["Knob"]/["Card"])才不能放到 15 键板上
        public let isKeypadAction: Bool

        public var stateCount: Int { stateImages.count }
    }

    /// 插件目录名(含 .sdPlugin 后缀),同时是安装目录的身份
    public let directoryName: String
    /// 插件 UUID = 目录名去 .sdPlugin 后缀(官方插件 manifest 顶层无 UUID 字段,目录名是权威来源)
    public let pluginUUID: String
    public let name: String
    public let version: String
    /// 插件入口相对路径(CodePathMac 优先于 CodePath;Windows 专用字段忽略)
    public let entryPathMac: String?
    public let actions: [Action]
    public let family: Family
    /// 旧风格顶层 PI 路径(v1 manifest 把 PI 页写在顶层;v2 挪进了各 action)
    public let propertyInspectorPath: String?

    /// 仅保留 Keypad 型 action(Knob/Card 等在 15 键板上无意义)
    public var keypadActions: [Action] { actions.filter(\.isKeypadAction) }

    /// 指定 action 的 PI 页面相对路径:action 级优先,顶层兜底;两处皆无返回 nil
    public func piPagePath(actionUUID: String) -> String? {
        let actionPath = actions.first { $0.uuid == actionUUID }?.propertyInspectorPath
        let candidates = [actionPath, propertyInspectorPath].compactMap { $0 }
        return candidates.first { !$0.isEmpty }
    }

    // MARK: - 解析

    public static func load(fromDirectory directoryURL: URL) throws -> SDManifest {
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try parse(data, directoryName: directoryURL.lastPathComponent)
    }

    public static func parse(_ data: Data, directoryName: String) throws -> SDManifest {
        let mirror = try JSONDecoder().decode(ManifestMirror.self, from: data)
        let actions = (mirror.Actions ?? []).compactMap { mirrorAction -> Action? in
            guard let uuid = mirrorAction.UUID, !uuid.isEmpty else { return nil }
            let stateImages = (mirrorAction.States ?? []).map(\.Image)
            return Action(
                uuid: uuid,
                name: mirrorAction.Name ?? uuid,
                stateImages: stateImages,
                disableAutomaticStates: mirrorAction.DisableAutomaticStates ?? false,
                propertyInspectorPath: mirrorAction.PropertyInspectorPath,
                isKeypadAction: mirrorAction.Controllers.map { $0.isEmpty || $0.contains("Keypad") } ?? true
            )
        }

        let entryPath = mirror.CodePathMac ?? mirror.CodePath
        let family: Family
        if entryPath?.hasSuffix(".js") == true {
            family = .node(mirror.Nodejs?["Version"])
        } else if entryPath?.hasSuffix(".html") == true {
            family = .html
        } else {
            family = .unsupported
        }

        return SDManifest(
            directoryName: directoryName,
            pluginUUID: directoryName.hasSuffix(".sdPlugin")
                ? String(directoryName.dropLast(".sdPlugin".count))
                : directoryName,
            name: mirror.Name ?? directoryName,
            version: mirror.Version ?? "0.0.0",
            entryPathMac: entryPath,
            actions: actions,
            family: family,
            propertyInspectorPath: mirror.PropertyInspector
        )
    }

    // MARK: - 图片解析

    /// manifest 图片路径 → 实际文件 URL。manifest 图标普遍无扩展名(如 "static/img/cate"),
    /// 按候选扩展名探测;返回 .svg 时调用方需自行决定是否支持(M2 不支持)。
    public static func resolveImageURL(pluginRoot: URL, manifestPath: String?) -> URL? {
        guard let manifestPath, !manifestPath.isEmpty else { return nil }
        let fileManager = FileManager.default
        let base = manifestPath.hasPrefix("/")
            ? URL(fileURLWithPath: manifestPath)
            : pluginRoot.appendingPathComponent(manifestPath)

        if base.pathExtension.isEmpty {
            for candidate in ["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg"] {
                let url = base.appendingPathExtension(candidate)
                if fileManager.fileExists(atPath: url.path) { return url }
            }
            return nil
        }
        return fileManager.fileExists(atPath: base.path) ? base : nil
    }
}

// MARK: - manifest 原始镜像(全部可选,宽容解码)

private struct ManifestMirror: Decodable {
    struct ActionMirror: Decodable {
        struct StateMirror: Decodable {
            var Image: String?
        }

        var UUID: String?
        var Name: String?
        var States: [StateMirror]?
        var Controllers: [String]?
        var DisableAutomaticStates: Bool?
        var PropertyInspectorPath: String?
    }

    var Name: String?
    var Version: String?
    var CodePath: String?
    var CodePathMac: String?
    var CodePathWin: String?
    var Nodejs: [String: String]?
    var Actions: [ActionMirror]?
    var PropertyInspector: String?
}
