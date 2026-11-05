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

// MARK: - §6.26 深度审计轮新增闸门

extension PluginSettingsStoreTests {
    /// 损坏文件:归档留底(settings.corrupt-*)后返回空文档。
    /// 旧行为静默清零——首次写盘即把残缺文件覆盖成空文档,用户 PI 参数无痕蒸发
    @Test("损坏文件归档留底后返回空文档")
    func corruptFileArchivedBeforeReset() throws {
        let dir = makeSandbox()
        let store = PluginSettingsStore(baseURL: dir)
        let url = dir.appendingPathComponent("com.test.corrupt.json")
        try Data("{ 这不是合法 JSON".utf8).write(to: url)

        let loaded = store.load(pluginUUID: "com.test.corrupt")
        #expect(loaded == PluginSettingsDocument())

        let archives = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("settings.corrupt-com.test.corrupt-") }
        #expect(archives.count == 1, "应恰好留底一份: \(archives)")
    }

    /// persist 失败必须可见(返回 false):磁盘满/权限时静默 = 内存真相与磁盘分叉无痕
    @Test("persist 落盘失败返回 false")
    func persistFailureReturnsFalse() throws {
        let dir = makeSandbox()
        // 在目录位置放一个同名文件,使 createDirectory/写盘必然失败
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let store = PluginSettingsStore(baseURL: blocker.appendingPathComponent("sub"))

        let ok = store.persist(PluginSettingsDocument(), pluginUUID: "com.test.fail")
        #expect(ok == false)
    }
}
