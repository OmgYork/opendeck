import Foundation
import Testing

@testable import PluginHost

/// 持久化汇往返测试。语义边界:Store 是哑存储(不持内存、不做合并),
/// 内存真相在 PluginHostModel.settingsDocs;写入方禁止用旧副本调 persist
/// (17:41 事故类:旧副本整份写回覆盖新数据)。
@Suite("PluginSettingsStore 持久化汇")
struct PluginSettingsStoreTests {
    private func makeSandbox() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("persist/load 往返:global + 多 context 的 settings/state 全保留")
    func roundTrip() throws {
        let dir = makeSandbox()
        let store = PluginSettingsStore(baseURL: dir)
        var document = PluginSettingsDocument()
        document.globalSettings = .object(["connected": .bool(true)])
        document.contexts["ctx-a"] = PluginContextRecord(settings: .object(["k": .string("v")]), state: 2)
        document.contexts["ctx-b"] = PluginContextRecord()

        store.persist(document, pluginUUID: "com.test.x")

        let loaded = store.load(pluginUUID: "com.test.x")
        #expect(loaded == document)
        #expect(loaded.contexts["ctx-a"]?.settings == .object(["k": .string("v")]))
        #expect(loaded.contexts["ctx-a"]?.state == 2)
        #expect(loaded.globalSettings["connected"] == .bool(true))
    }

    @Test("缺失文件与坏文件都返回空文档")
    func missingAndBrokenFile() throws {
        let dir = makeSandbox()
        let store = PluginSettingsStore(baseURL: dir)
        #expect(store.load(pluginUUID: "com.test.none") == PluginSettingsDocument())

        let url = dir.appendingPathComponent("com.test.broken.json")
        try Data("不是 JSON".utf8).write(to: url)
        #expect(store.load(pluginUUID: "com.test.broken") == PluginSettingsDocument())
    }

    @Test("removeDocument 删文件,再 load 回空文档")
    func removeDocument() throws {
        let dir = makeSandbox()
        let store = PluginSettingsStore(baseURL: dir)
        var document = PluginSettingsDocument()
        document.contexts["ctx"] = PluginContextRecord(state: 1)
        store.persist(document, pluginUUID: "com.test.y")
        #expect(store.load(pluginUUID: "com.test.y").contexts["ctx"] != nil)

        store.removeDocument(pluginUUID: "com.test.y")
        #expect(store.load(pluginUUID: "com.test.y") == PluginSettingsDocument())
    }

    @Test("空文档 persist:context 记录可清空(整份覆盖是持久化汇的合法语义)")
    func persistEmpty() throws {
        let dir = makeSandbox()
        let store = PluginSettingsStore(baseURL: dir)
        var document = PluginSettingsDocument()
        document.contexts["ctx"] = PluginContextRecord(state: 3)
        store.persist(document, pluginUUID: "com.test.z")

        store.persist(PluginSettingsDocument(), pluginUUID: "com.test.z")
        #expect(store.load(pluginUUID: "com.test.z") == PluginSettingsDocument())
    }
}
