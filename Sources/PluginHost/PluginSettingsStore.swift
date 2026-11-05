import Foundation
import os

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
/// 本类只负责「整文档原子落盘 / 从盘加载 / 删除」。原子写;文件缺失 = 空文档;
/// 损坏 = 归档留底后返回空文档(与 config.json 同一原则:绝不悄悄覆掉用户参数)。
public final class PluginSettingsStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "opendeck", category: "plugin-settings")
    private let baseURL: URL
    private let lock = NSLock()

    public init(baseURL: URL) {
        self.baseURL = baseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// 从盘加载;文件缺失返回空文档;损坏先归档(settings.corrupt-<uuid>-<时间戳>.json)
    /// 再返回空文档——否则首次写盘就会把残缺文件静默覆盖成空文档,用户参数无痕蒸发
    public func load(pluginUUID: String) -> PluginSettingsDocument {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: pluginUUID)
        guard let data = try? Data(contentsOf: url) else { return PluginSettingsDocument() }
        do {
            return try JSONDecoder().decode(PluginSettingsDocument.self, from: data)
        } catch {
            Self.logger.fault("settings 文件损坏[\(pluginUUID, privacy: .public)]:\(error, privacy: .public)")
            archiveCorrupt(data: data, pluginUUID: pluginUUID, reason: "undecodable")
            return PluginSettingsDocument()
        }
    }

    /// 整文档原子落盘。仅限内存真相持有方(PluginHostModel)在变更后调用——
    /// 禁止用旧副本调用,否则会覆盖新数据(17:41 事故的失败类)。
    /// 返回 false = 落盘失败(磁盘满/权限):内存真相与磁盘已分叉,调用方必须上报,
    /// 静默的话重启加载到旧文件、失败点之后的变更全部丢失且无痕迹
    @discardableResult
    public func persist(_ document: PluginSettingsDocument, pluginUUID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(document) else {
            Self.logger.fault("settings 编码失败[\(pluginUUID, privacy: .public)]")
            return false
        }
        do {
            try data.write(to: fileURL(for: pluginUUID), options: .atomic)
            return true
        } catch {
            Self.logger.fault("settings 落盘失败[\(pluginUUID, privacy: .public)]:\(error, privacy: .public)")
            return false
        }
    }

    /// 卸载插件时清掉其设置文件。优先移废纸篓(与插件目录卸载同语义,误卸载可恢复),
    /// 废纸篓失败退回直接删除
    public func removeDocument(pluginUUID: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: pluginUUID)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 损坏归档:同目录 settings.corrupt-<uuid>-<毫秒时间戳>-<原因>.json。
    /// 毫秒时间戳防同秒碰撞互相覆盖;归档失败仅记日志(原文件仍在,不继续破坏现场)
    private func archiveCorrupt(data: Data, pluginUUID: String, reason: String) {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let archiveURL = baseURL
            .appendingPathComponent("settings.corrupt-\(pluginUUID)-\(stamp)-\(reason).json")
        do {
            try data.write(to: archiveURL, options: .atomic)
            Self.logger.error("损坏 settings 已归档:\(archiveURL.path, privacy: .public)")
        } catch {
            Self.logger.fault("损坏 settings 归档失败:\(error, privacy: .public)")
        }
    }

    private func fileURL(for pluginUUID: String) -> URL {
        baseURL.appendingPathComponent("\(pluginUUID).json")
    }
}
