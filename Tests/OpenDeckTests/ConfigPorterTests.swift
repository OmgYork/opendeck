import Foundation
import PluginHost
import Testing
@testable import OpenDeck

/// 配置备份导出/导入(§6.29):ditto 打包 → 校验暂存 → 启动应用的全链契约。
/// 要害:导入 = 「整机还原」语义(config + 插件参数 + 插件本体);暂存-应用两段式
/// 保证运行中实例的内存真相永不被热替换。
@MainActor
@Suite("ConfigPorter 配置备份")
struct ConfigPorterTests {
    private func waitPort(_ model: PluginHostModel) async throws {
        for _ in 0..<150 where model.port == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.port != 0, "服务未就绪")
    }

    private func makeTempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-porter-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSandboxWithPlugin() throws -> (plugins: URL, settings: URL, pluginUUID: String) {
        let plugins = makeTempDir("plugins")
        let settings = makeTempDir("settings")
        let pluginUUID = "com.test.porter"
        let pluginDir = plugins.appendingPathComponent("\(pluginUUID).sdPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = #"{"Name":"porter","Version":"1.0","CodePath":"index.html","Actions":[{"UUID":"com.test.porter.action","Name":"A"}]}"#
        try Data(manifest.utf8).write(to: pluginDir.appendingPathComponent("manifest.json"))
        try Data("<html></html>".utf8).write(to: pluginDir.appendingPathComponent("index.html"))
        // 预置参数文档(syncKey 懒加载后进内存真相)
        let doc = #"{"globalSettings":{"connected":true},"contexts":{"ctx-p":{"settings":{"k":"v"},"state":0}}}"#
        try Data(doc.utf8).write(to: settings.appendingPathComponent("\(pluginUUID).json"))
        return (plugins, settings, pluginUUID)
    }

    @Test("导出 → 应用 → 配置/参数/插件全量还原")
    func exportThenApplyRestoresEverything() async throws {
        let sandbox = try makeSandboxWithPlugin()
        let config = ConfigStore(contentsOf: makeTempDir("cfg").appendingPathComponent("config.json"))
        config.updateKey(KeyConfig(title: "状态灯", backgroundColorHex: "#BF616A"), at: 3)
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start() // 装载 installedPlugins(否则 ensureRuntime 失败,settings 文档不进内存)
        try await waitPort(model)
        model.syncKey(at: 3, action: .plugin(
            pluginID: sandbox.pluginUUID, actionUUID: "com.test.porter.action", contextID: "ctx-p"
        )) // 懒加载 settings 文档进内存真相
        model.shutdown()

        let archive = makeTempDir("out").appendingPathComponent("backup.zip")
        let iconsBase = makeTempDir("icons")
        try Data([0x89]).write(to: iconsBase.appendingPathComponent("key-icons-test.png"))
        let report = try ConfigPorter.exportConfig(
            to: archive, config: config, pluginHost: model,
            iconsBase: FileManager.default.temporaryDirectory // 无 key-icons 目录:走空分支
        )
        #expect(report.pluginCount == 1)
        #expect(report.settingsDocumentCount == 1)

        // 应用到全新的「应用支持目录」
        let appSupport = makeTempDir("support")
        let staged = try ConfigPorter.validateAndStageImport(from: archive, pendingRoot: appSupport)
        #expect(staged.sceneCount == 1)
        #expect(staged.pluginCount == 1)
        #expect(staged.settingsDocumentCount == 1)
        #expect(staged.skippedSettingsFiles == 0)
        let applied = ConfigPorter.applyPendingImport(appSupport: appSupport)
        #expect(applied)

        // config.json 还原(含导入前编辑的第 4 键)
        let restored = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: appSupport.appendingPathComponent("config.json")))
        #expect(restored.scenes[0].pages[0].keys[3].title == "状态灯")
        #expect(restored.scenes[0].pages[0].keys[3].backgroundColorHex == "#BF616A")
        // 插件本体还原
        #expect(FileManager.default.fileExists(
            atPath: appSupport.appendingPathComponent("plugins/\(sandbox.pluginUUID).sdPlugin/manifest.json").path))
        // 参数文档还原
        #expect(FileManager.default.fileExists(
            atPath: appSupport.appendingPathComponent("pluginSettings/\(sandbox.pluginUUID).json").path))
        // 暂存已清
        #expect(!FileManager.default.fileExists(atPath: appSupport.appendingPathComponent(ConfigPorter.pendingImportDirName).path))
    }

    @Test("拒绝:包里没有 config.json / schema 超前")
    func rejectsMissingConfigAndNewerSchema() async throws {
        // 空包:先造一个合法 zip(仅 backup.json)
        let sandbox = try makeSandboxWithPlugin()
        let config = ConfigStore(contentsOf: makeTempDir("cfg2").appendingPathComponent("config.json"))
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start()
        try await waitPort(model)
        model.shutdown()
        let emptyArchive = makeTempDir("out2").appendingPathComponent("empty.zip")
        _ = try ConfigPorter.exportConfig(to: emptyArchive, config: config, pluginHost: model)

        // 从合法包抽走 config.json:重打一个不含它的 zip(用 ditto 解包删文件再打包)
        let work = makeTempDir("work")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.currentDirectoryURL = work
        unzip.arguments = ["-x", "-k", emptyArchive.path, "."]
        try unzip.run(); unzip.waitUntilExit()
        try FileManager.default.removeItem(at: work.appendingPathComponent("config.json"))
        let stripped = makeTempDir("out3").appendingPathComponent("stripped.zip")
        let rezip = Process()
        rezip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        rezip.currentDirectoryURL = work
        rezip.arguments = ["-c", "-k", ".", stripped.path]
        try rezip.run(); rezip.waitUntilExit()

        #expect(throws: ConfigPorter.PorterError.missingConfig) {
            try ConfigPorter.validateAndStageImport(from: stripped, pendingRoot: makeTempDir("p1"))
        }

        // schema 超前
        let newer = """
        {"scenes":[],"schemaVersion":3}
        """
        let newerDir = makeTempDir("newer")
        try Data(newer.utf8).write(to: newerDir.appendingPathComponent("config.json"))
        let newerZip = makeTempDir("out4").appendingPathComponent("newer.zip")
        let zipNewer = Process()
        zipNewer.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipNewer.currentDirectoryURL = newerDir
        zipNewer.arguments = ["-c", "-k", ".", newerZip.path]
        try zipNewer.run(); zipNewer.waitUntilExit()

        #expect(throws: ConfigPorter.PorterError.newerSchema(3)) {
            try ConfigPorter.validateAndStageImport(from: newerZip, pendingRoot: makeTempDir("p2"))
        }
    }

    @Test("损坏参数文件跳过计数,有效文档照常还原")
    func skipsBrokenSettingsFiles() async throws {
        let sandbox = try makeSandboxWithPlugin()
        try Data("不是 JSON".utf8).write(to: sandbox.settings.appendingPathComponent("com.broken.json"))
        let config = ConfigStore(contentsOf: makeTempDir("cfg3").appendingPathComponent("config.json"))
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start()
        try await waitPort(model)
        model.shutdown()

        let archive = makeTempDir("out5").appendingPathComponent("backup.zip")
        _ = try ConfigPorter.exportConfig(to: archive, config: config, pluginHost: model)
        // 导出取内存真相(broken 文件未懒加载不在内存)——补一份坏文件进包验证导入侧跳过
        let work = makeTempDir("work2")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.currentDirectoryURL = work
        unzip.arguments = ["-x", "-k", archive.path, "."]
        try unzip.run(); unzip.waitUntilExit()
        let settingsInWork = work.appendingPathComponent("pluginSettings", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsInWork, withIntermediateDirectories: true)
        try Data("坏".utf8).write(to: settingsInWork.appendingPathComponent("com.broken.json"))
        let repacked = makeTempDir("out6").appendingPathComponent("repacked.zip")
        let rezip = Process()
        rezip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        rezip.currentDirectoryURL = work
        rezip.arguments = ["-c", "-k", ".", repacked.path]
        try rezip.run(); rezip.waitUntilExit()

        let appSupport = makeTempDir("support2")
        let staged = try ConfigPorter.validateAndStageImport(from: repacked, pendingRoot: appSupport)
        #expect(staged.skippedSettingsFiles == 1)
        #expect(staged.settingsDocumentCount == 0, "包内唯一有效文档未懒加载,导出内存真相为空")
    }
}
