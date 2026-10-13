import Foundation

/// 单个 action 实例(context)的持久化记录
public struct PluginContextRecord: Codable, Equatable, Sendable {
    public var settings: JSONValue
    /// 当前状态(manifest 多状态 action 的下标)
    public var state: Int

    public init(settings: JSONValue = .object([:]), state: Int = 0) {
        self.settings = settings
        self.state = state
    }
}

/// 单个插件的持久化文档:全局 settings + 各 context 的 settings/state
public struct PluginSettingsDocument: Codable, Equatable, Sendable {
    public var globalSettings: JSONValue = .object([:])
    public var contexts: [String: PluginContextRecord] = [:]

    public init() {}
}

/// per-plugin settings 持久化:~/Library/Application Support/OpenDeck/pluginSettings/<pluginUUID>.json。
/// 原子写;文件缺失 = 空文档。写入由上层(主线程)调用,内部加锁兜底。
public final class PluginSettingsStore: @unchecked Sendable {
    private let baseURL: URL
    private let lock = NSLock()

    public init(baseURL: URL) {
        self.baseURL = baseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    public func document(pluginUUID: String) -> PluginSettingsDocument {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: pluginUUID)
        guard let data = try? Data(contentsOf: url) else { return PluginSettingsDocument() }
        // 坏文件按空文档处理,下次 save 覆盖修复
        return (try? JSONDecoder().decode(PluginSettingsDocument.self, from: data)) ?? PluginSettingsDocument()
    }

    public func save(_ document: PluginSettingsDocument, pluginUUID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: fileURL(for: pluginUUID), options: .atomic)
    }

    /// 卸载插件时清掉其设置文件
    public func removeDocument(pluginUUID: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(for: pluginUUID))
    }

    private func fileURL(for pluginUUID: String) -> URL {
        baseURL.appendingPathComponent("\(pluginUUID).json")
    }
}
