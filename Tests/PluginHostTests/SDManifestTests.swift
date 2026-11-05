import Foundation
import Testing

@testable import PluginHost

/// manifest 解析测试:字段形态对照官方 OBS 插件实况(2 态/DisableAutomaticStates/无扩展名图片)
@Suite("SDManifest 解析")
struct SDManifestTests {
    private static let nodeManifestJSON = #"""
    {
      "Name": "obs studio",
      "Version": "1.0.260806",
      "SDKVersion": 1,
      "CodePath": "plugin/index.js",
      "CodePathWin": "plugin/index.js",
      "CodePathMac": "plugin/index.js",
      "Nodejs": { "Version": "20" },
      "Software": { "MinimumVersion": "3.10.188.226" },
      "OS": [{ "Platform": "mac", "MinimumVersion": "10.11" }],
      "Actions": [
        {
          "UUID": "com.mirabox.streamdock.obs.studio.stream",
          "Name": "Streaming",
          "DisableAutomaticStates": true,
          "States": [
            { "Image": "actions/stream/images/off" },
            { "Image": "actions/stream/images/on" }
          ]
        },
        {
          "UUID": "com.mirabox.streamdock.obs.studio.media",
          "Name": "Media",
          "States": [
            { "Image": "actions/media/images/a" },
            { "Image": "actions/media/images/b" },
            { "Image": "actions/media/images/c" },
            { "Image": "actions/media/images/d" },
            { "Image": "actions/media/images/e" },
            { "Image": "actions/media/images/f" }
          ]
        },
        {
          "Name": "缺 UUID 的坏 action,应被跳过"
        }
      ]
    }
    """#

    @Test("Node 家族黄金解析:CodePathMac 优先、多状态、无 UUID 的 action 跳过")
    func parseNodeManifest() throws {
        let manifest = try SDManifest.parse(Data(Self.nodeManifestJSON.utf8),
                                            directoryName: "com.mirabox.streamdock.obs.studio.sdPlugin")
        #expect(manifest.pluginUUID == "com.mirabox.streamdock.obs.studio")
        #expect(manifest.name == "obs studio")
        #expect(manifest.version == "1.0.260806")
        #expect(manifest.entryPathMac == "plugin/index.js")
        #expect(manifest.family == .node("20"))
        #expect(manifest.family.isNode)
        #expect(manifest.actions.count == 2) // 无 UUID 的第三条被跳过

        let stream = try #require(manifest.actions.first)
        #expect(stream.uuid == "com.mirabox.streamdock.obs.studio.stream")
        #expect(stream.stateImages == ["actions/stream/images/off", "actions/stream/images/on"])
        #expect(stream.disableAutomaticStates == true) // OBS 全系动作如此,宿主不做自动状态轮换
        #expect(stream.isKeypadAction) // Controllers 缺省 = Keypad

        let media = manifest.actions[1]
        #expect(media.stateCount == 6) // 媒体键 6 态
        #expect(media.disableAutomaticStates == false) // 缺省 false → 宿主需自动轮换
    }

    @Test("HTML 家族识别(M2 不支持)与 Knob 型过滤;空 Controllers = 不限制")
    func parseHTMLAndKnob() throws {
        let unrestricted = try SDManifest.parse(
            Data(#"{"CodePath":"plugin/index.js","Nodejs":{"Version":"20"},"Actions":[{"UUID":"u","Name":"U","Controllers":[]}]}"#.utf8),
            directoryName: "com.x.u.sdPlugin"
        )
        #expect(unrestricted.keypadActions.count == 1) // OBS 插件实况:空数组 = 全控制器可用
        let html = try SDManifest.parse(
            Data(#"{"Name":"clock","CodePath":"index.html","Actions":[{"UUID":"a","Name":"A"}]}"#.utf8),
            directoryName: "com.x.clock.sdPlugin"
        )
        #expect(html.family == .html)
        #expect(!html.family.isNode)

        let knob = try SDManifest.parse(
            Data(#"{"CodePath":"plugin/index.js","Nodejs":{"Version":"20"},"Actions":[{"UUID":"k","Name":"K","Controllers":["Knob"]}]}"#.utf8),
            directoryName: "com.x.knob.sdPlugin"
        )
        #expect(knob.family.isNode)
        #expect(knob.actions.count == 1)
        #expect(knob.keypadActions.isEmpty) // Knob 型 action 对 15 键板不可用
    }

    @Test("CodePathMac 缺失时回退 CodePath;家族无法识别")
    func parseFallback() throws {
        let manifest = try SDManifest.parse(
            Data(#"{"Name":"m","CodePath":"plugin/main.js","Actions":[]}"#.utf8),
            directoryName: "com.x.m.sdPlugin"
        )
        #expect(manifest.entryPathMac == "plugin/main.js")
        #expect(manifest.family.isNode)

        let broken = try SDManifest.parse(
            Data(#"{"Name":"b","Actions":[]}"#.utf8),
            directoryName: "com.x.b.sdPlugin"
        )
        #expect(broken.family == .unsupported)
    }

    @Test("PI 页面路径:action 级优先,顶层 PropertyInspector 兜底,空串视为未配置")
    func piPagePath() throws {
        let manifest = try SDManifest.parse(Data(#"""
        {
          "CodePath": "plugin/index.js",
          "PropertyInspector": "pi/top.html",
          "Actions": [
            { "UUID": "a1", "Name": "A1", "PropertyInspectorPath": "pi/action.html" },
            { "UUID": "a2", "Name": "A2", "PropertyInspectorPath": "" },
            { "UUID": "a3", "Name": "A3" }
          ]
        }
        """#.utf8), directoryName: "com.x.pi.sdPlugin")
        #expect(manifest.piPagePath(actionUUID: "a1") == "pi/action.html")
        #expect(manifest.piPagePath(actionUUID: "a2") == "pi/top.html")
        #expect(manifest.piPagePath(actionUUID: "a3") == "pi/top.html")
        #expect(manifest.piPagePath(actionUUID: "missing") == "pi/top.html")

        let topOnly = try SDManifest.parse(
            Data(#"{"CodePath":"plugin/index.js","Actions":[{"UUID":"a","Name":"A"}]}"#.utf8),
            directoryName: "com.x.t.sdPlugin")
        #expect(topOnly.piPagePath(actionUUID: "a") == nil)
    }

    @Test("OpenDeck 扩展字段 ActivateAppBundleID:声明可解析,缺省为 nil")
    func parseActivateAppBundleID() throws {
        let declared = try SDManifest.parse(
            Data(#"{"CodePath":"index.html","Actions":[{"UUID":"a","Name":"A","ActivateAppBundleID":"dev.zcode.app"}]}"#.utf8),
            directoryName: "com.x.light.sdPlugin"
        )
        #expect(declared.actions.first?.activateAppBundleID == "dev.zcode.app")

        let absent = try SDManifest.parse(
            Data(#"{"CodePath":"index.html","Actions":[{"UUID":"a","Name":"A"}]}"#.utf8),
            directoryName: "com.x.light.sdPlugin"
        )
        #expect(absent.actions.first?.activateAppBundleID == nil)
    }

    @Test("图片扩展名探测:manifest 无扩展名 → 实际 .png")
    func resolveImageExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images = root.appendingPathComponent("actions/stream/images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([0x89]).write(to: images.appendingPathComponent("off.png"))

        let resolved = SDManifest.resolveImageURL(pluginRoot: root, manifestPath: "actions/stream/images/off")
        #expect(resolved?.lastPathComponent == "off.png")
        #expect(SDManifest.resolveImageURL(pluginRoot: root, manifestPath: "actions/stream/images/missing") == nil)
        #expect(SDManifest.resolveImageURL(pluginRoot: root, manifestPath: nil) == nil)
        #expect(SDManifest.resolveImageURL(pluginRoot: root, manifestPath: "") == nil)

        try? FileManager.default.removeItem(at: root)
    }

    @Test("load(fromDirectory:):从磁盘读 manifest.json")
    func loadFromDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.nodeManifestJSON.utf8).write(to: root.appendingPathComponent("manifest.json"))

        let manifest = try SDManifest.load(fromDirectory: root)
        #expect(manifest.directoryName == root.lastPathComponent)
        #expect(manifest.pluginUUID == root.lastPathComponent.dropSuffix(".sdPlugin"))

        try? FileManager.default.removeItem(at: root)
    }
}

private extension String {
    func dropSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

// MARK: - §6.26 深度审计轮新增闸门

extension SDManifestTests {
    /// resolveImageURL 沙盒:绝对路径与 ".." 穿越一律拒(manifest 是插件作者控制的输入)
    @Test("resolveImageURL 沙盒:相对可解析,绝对路径与穿越拒绝")
    func resolveImageURLSandbox() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-manifest-sandbox-\(UUID().uuidString)")
        let images = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([0x89]).write(to: images.appendingPathComponent("icon.png"))

        // 相对路径:无扩展名探测命中
        #expect(SDManifest.resolveImageURL(pluginRoot: root, manifestPath: "images/icon") != nil)
        // 绝对路径:即使真实存在也拒
        #expect(SDManifest.resolveImageURL(pluginRoot: root, manifestPath: "/etc/hosts") == nil)
        // ".." 穿越越出插件根:拒
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.png")
        try Data([0x89]).write(to: outside)
        #expect(SDManifest.resolveImageURL(pluginRoot: root, manifestPath: "images/../../outside") == nil)
    }

    /// canonicalPath:符号链接目录与真身同一路径;不存在的末段保留原样但前缀已解析
    @Test("canonicalPath:软链等价 + 不存在末段保留")
    func canonicalPathResolvesSymlinks() throws {
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-canonical-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = real.deletingLastPathComponent().appendingPathComponent("opendeck-canonical-link-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(SDManifest.canonicalPath(link) == SDManifest.canonicalPath(real))
        // 末段不存在(realpath 逐级退化):前缀仍是真身路径
        let ghost = link.appendingPathComponent("no/such/file.json")
        let canonicalGhost = SDManifest.canonicalPath(ghost)
        #expect(canonicalGhost.hasPrefix(SDManifest.canonicalPath(real)))
        #expect(canonicalGhost.hasSuffix("no/such/file.json"))
        try? FileManager.default.removeItem(at: link)
    }
}
