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
/// 纯持久化汇(哑存储):不持有内存状态、不做合并——内存真相归 PluginHostModel.settingsDocs,
/// 本类只负责「整文档原子落盘 / 从盘加载 / 删除」。原子写;文件缺失或损坏 = 空文档。
public final class PluginSettingsStore: @unchecked Sendable {
    private let baseURL: URL
    private let lock = NSLock()

    public init(baseURL: URL) {
        self.baseURL = baseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// 从盘加载;文件缺失或损坏返回空文档
    public func load(pluginUUID: String) -> PluginSettingsDocument {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: pluginUUID)
        guard let data = try? Data(contentsOf: url) else { return PluginSettingsDocument() }
        return (try? JSONDecoder().decode(PluginSettingsDocument.self, from: data)) ?? PluginSettingsDocument()
    }

    /// 整文档原子落盘。仅限内存真相持有方(PluginHostModel)在变更后调用——
    /// 禁止用旧副本调用,否则会覆盖新数据(17:41 事故的失败类)
    public func persist(_ document: PluginSettingsDocument, pluginUUID: String) {
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
