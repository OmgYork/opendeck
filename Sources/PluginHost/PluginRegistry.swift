import Foundation

/// 已安装插件:manifest + 所在目录
public struct InstalledPlugin: Sendable, Equatable {
    public let manifest: SDManifest
    public let directoryURL: URL
}

public enum PluginInstallError: Error, Equatable {
    case sourceNotFound
    case notAPlugin
    case alreadyInstalled(String)
    case archiveEmpty
    case trashFailed
}

/// 本地插件库:唯一插件根(拷贝制)下的扫描/安装/导入/卸载。
/// 安装 = 校验 manifest 后整目录拷贝(来源不动);卸载 = 移入废纸篓。
public final class PluginRegistry: @unchecked Sendable {
    /// 官方 StreamDock.app 的已装插件目录(过渡助迁的拷贝来源,只读)
    public static var officialPluginsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HotSpot/StreamDock/plugins")
    }

    public let pluginsRoot: URL

    public init(pluginsRoot: URL) {
        self.pluginsRoot = pluginsRoot
        try? FileManager.default.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
    }

    /// 默认插件根:~/Library/Application Support/OpenDeck/plugins/
    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenDeck/plugins")
    }

    // MARK: - 扫描

    /// 扫描插件根;坏目录跳过并作为诊断信息返回(不中断整体)
    public func installedPlugins() -> (plugins: [InstalledPlugin], broken: [String]) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: pluginsRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return ([], []) }

        var plugins: [InstalledPlugin] = []
        var broken: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory, entry.lastPathComponent.hasSuffix(".sdPlugin") else { continue }
            do {
                let manifest = try SDManifest.load(fromDirectory: entry)
                plugins.append(InstalledPlugin(manifest: manifest, directoryURL: entry))
            } catch {
                broken.append("\(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (plugins, broken)
    }

    public func installedPlugin(pluginUUID: String) -> InstalledPlugin? {
        installedPlugins().plugins.first { $0.manifest.pluginUUID == pluginUUID }
    }

    // MARK: - 安装

    /// 安装来源:.sdPlugin 目录(或含 manifest.json 的任意目录名)/ .streamDeckPlugin(ZIP)文件
    @discardableResult
    public func install(from sourceURL: URL) throws -> SDManifest {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw PluginInstallError.sourceNotFound
        }

        if isDirectory.boolValue {
            return try installDirectory(at: sourceURL)
        }
        guard ["zip", "streamdeckplugin"].contains(sourceURL.pathExtension.lowercased()) else {
            throw PluginInstallError.notAPlugin
        }
        return try installArchive(at: sourceURL)
    }

    /// 从官方 StreamDock 插件目录批量导入 Node 家族插件(拷贝,官方目录不动)。
    /// 返回逐个结果:name = 插件目录名,message = 失败原因(成功为 nil)。
    public func importFromOfficialDirectory() -> [(name: String, error: String?)] {
        let officialDir = Self.officialPluginsDirectory
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: officialDir, includingPropertiesForKeys: nil) else {
            return [("官方插件目录不可访问(\(officialDir.path))", "sourceNotFound")]
        }
        var results: [(String, String?)] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard entry.lastPathComponent.hasSuffix(".sdPlugin"),
                  let manifest = try? SDManifest.load(fromDirectory: entry),
                  manifest.family.isHostable
            else { continue } // 无法识别家族不导入(node/html 均可承载)
            do {
                try installDirectory(at: entry)
                results.append((entry.lastPathComponent, nil))
            } catch PluginInstallError.alreadyInstalled {
                results.append((entry.lastPathComponent, nil)) // 已装 = 导入目标已达成
            } catch {
                results.append((entry.lastPathComponent, String(describing: error)))
            }
        }
        return results
    }

    // MARK: - 卸载

    /// 移入废纸篓(可恢复),同时上层应调用 PluginSettingsStore.removeDocument
    public func uninstall(directoryName: String) throws {
        let target = pluginsRoot.appendingPathComponent(directoryName)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw PluginInstallError.sourceNotFound
        }
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        } catch {
            throw PluginInstallError.trashFailed
        }
    }

    // MARK: - 私有

    @discardableResult
    private func installDirectory(at sourceURL: URL) throws -> SDManifest {
        let manifest = try SDManifest.load(fromDirectory: sourceURL)
        let destinationName = sourceURL.lastPathComponent.hasSuffix(".sdPlugin")
            ? sourceURL.lastPathComponent
            : sourceURL.lastPathComponent + ".sdPlugin"
        let destination = pluginsRoot.appendingPathComponent(destinationName)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw PluginInstallError.alreadyInstalled(destinationName)
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination) // 半截拷贝回滚
            throw PluginInstallError.notAPlugin
        }
        return manifest
    }

    /// .streamDeckPlugin = 标准 ZIP 包(Elgato distribution tool 产出),ditto 解包后找 .sdPlugin 目录
    private func installArchive(at sourceURL: URL) throws -> SDManifest {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", sourceURL.path, workDirectory.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw PluginInstallError.notAPlugin }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: workDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { throw PluginInstallError.archiveEmpty }

        let pluginDirectories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && $0.lastPathComponent.hasSuffix(".sdPlugin")
        }
        guard let pluginDirectory = pluginDirectories.first else { throw PluginInstallError.archiveEmpty }
        return try installDirectory(at: pluginDirectory)
    }
}
