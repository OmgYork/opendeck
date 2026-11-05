import Foundation
import Testing
@testable import OpenDeck

/// 键位复制/粘贴(§6.30)与页面/场景重排序、自动滚动备份的契约测试。
/// 剪贴板/重排序的用户可见语义在 ContextMenu,纯函数与数据层在此钉死。
@MainActor
@Suite("键位剪贴板与重排序")
struct KeyClipboardTests {
    @Test("粘贴政策:整键复刻含底色;插件键新 contextID;非插件键原样")
    func pastedConfigPolicy() {
        let plain = KeyConfig(title: "亮度+", backgroundColorHex: "#BF616A",
                              action: .monitor(.brightnessUp))
        let pasted = AppModel.pastedConfig(clip: plain, onto: KeyConfig(title: "目标"))
        #expect(pasted.title == "亮度+")
        #expect(pasted.backgroundColorHex == "#BF616A", "底色跟随来源(整键复刻)")
        #expect(pasted.action == .monitor(.brightnessUp))

        let plugin = KeyConfig(title: "灯", action: .plugin(
            pluginID: "com.x", actionUUID: "com.x.a", contextID: "shared-ctx"
        ))
        let pastedPlugin = AppModel.pastedConfig(clip: plugin, onto: KeyConfig())
        guard case .plugin(_, _, let newContext) = pastedPlugin.action else {
            Issue.record("插件动作应原样保留(换 context)")
            return
        }
        #expect(newContext != "shared-ctx", "克隆必须生成新 contextID(共享会互抢实例)")
    }

    @Test("movePage:圆点重排,当前指针按 id 跟随")
    func movePageFollowsCurrentByID() throws {
        let store = try makeStore(pages: 3, current: 2)
        let idC = store.config.scenes[0].pages[2].id // 移动前采集 C 的 id
        store.movePage(sceneIndex: 0, from: 2, to: 0) // 当前页 [A,B,C] 看着 C,移到最前
        #expect(store.config.currentPageIndex == 0, "指针应跟到 C 的新位置")
        #expect(store.config.scenes[0].pages[0].id == idC, "C 应在最前")
    }

    @Test("movePage:移动别的页跨过当前页,指针补偿")
    func moveOtherPageCompensatesCurrent() throws {
        let store = try makeStore(pages: 4, current: 2) // 看着 C
        store.movePage(sceneIndex: 0, from: 0, to: 3) // A 挪到末尾 [B,C,D,A]
        #expect(store.config.currentPageIndex == 1, "C 前面少了一页,指针应 -1")
    }

    @Test("moveScene:芯片重排,当前场景指针按 id 跟随")
    func moveSceneFollowsCurrentByID() throws {
        let store = try makeStore(pages: 1, current: 0, scenes: 3, currentScene: 2)
        store.moveScene(from: 2, to: 0)
        #expect(store.config.currentSceneIndex == 0, "视野场景应跟随移动")
        // 移动别的场景跨过当前:补偿
        store.moveScene(from: 2, to: 0) // [S3,S1,S2] 把 S2 挪到最前
        #expect(store.config.currentSceneIndex == 1, "S3 前面多了一页,指针应 +1")
    }

    @Test("自动备份:配置有变才打新包,滚动保留 10 份,手动备份不被清理")
    func autoBackupRotation() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-autobk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let configFile = support.appendingPathComponent("config.json")
        try Data("{\"scenes\":[],\"schemaVersion\":2}".utf8).write(to: configFile)
        let backupRoot = support.appendingPathComponent("backups", isDirectory: true)
        let plugins = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-autobk-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let config = ConfigStore(contentsOf: configFile)
        let model = PluginHostModel(pluginsRoot: plugins, settingsRoot: support)

        // 首跑:打一份
        ConfigPorter.runAutoBackupIfNeeded(config: config, pluginHost: model,
                                           backupRoot: backupRoot, configFile: configFile)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backupRoot.path)
            .filter { $0.hasPrefix("auto-") }.count == 1)
        // 配置未变:不重复
        ConfigPorter.runAutoBackupIfNeeded(config: config, pluginHost: model,
                                           backupRoot: backupRoot, configFile: configFile)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backupRoot.path)
            .filter { $0.hasPrefix("auto-") }.count == 1)
        // 手动备份不进滚动清理
        try Data("manual".utf8).write(to: backupRoot.appendingPathComponent("manual-backup.zip"))
        // 配置变化 + 已有 11 份 auto:只留最新 10 份,manual 保留
        for index in 0..<11 {
            let name = backupRoot.appendingPathComponent(String(format: "auto-202611%02d-120000.zip", index))
            try Data("old".utf8).write(to: name)
        }
        try Data("{\"scenes\":[],\"schemaVersion\":2,\"brightness\":77}".utf8).write(to: configFile)
        ConfigPorter.runAutoBackupIfNeeded(config: config, pluginHost: model,
                                           backupRoot: backupRoot, configFile: configFile)
        let auto = try FileManager.default.contentsOfDirectory(atPath: backupRoot.path)
            .filter { $0.hasPrefix("auto-") }
        #expect(auto.count == 10, "滚动保留 10 份,实存 \(auto.count)")
        #expect(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent("manual-backup.zip").path))
    }

    private func makeStore(pages: Int, current: Int, scenes: Int = 1, currentScene: Int = 0) throws -> ConfigStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let sceneJSON: [String] = (0..<scenes).map { scene in
            let pageList: [String] = (0..<pages).map { page in
                #"{"keys":[]}"#
            }
            _ = scene
            return #"{"name":"S\#(scene)","pages":["# + pageList.joined(separator: ",") + #"]}"#
        }
        let json = """
        {"scenes":[\(sceneJSON.joined(separator: ","))],
         "currentSceneIndex":\(currentScene),
         "currentPageIndex":\(current),
         "brightness":80}
        """
        try Data(json.utf8).write(to: url)
        return ConfigStore(contentsOf: url)
    }
}
