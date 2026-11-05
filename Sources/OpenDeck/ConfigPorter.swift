import AppKit
import Foundation
import os
import PluginHost

/// 配置备份的导出与导入(§6.29)。
///
/// 形态:单个 zip(ditto 系统工具打包,零依赖),内容 = config.json + pluginSettings/
/// + plugins/ + key-icons/ + app-icons/ + backup.json(元数据)。插件目录一并打包——
/// 配置引用的插件 UUID 没有插件本体就是死键,备份的语义是「整机还原」。
///
/// 导入采用「暂存 + 下次启动生效」两段式:内存即真相架构(§6.10)下运行中的实例
/// 持有唯一权威副本,热替换盘上文件会被退出时的落盘兜底覆盖;暂存到 pending-import/
/// 后由 ConfigStore 默认路径 init 在**任何配置读取之前**应用,新实例从第一行代码起
/// 就是导入后的世界。应用顺序:settings/icons/plugins 先行,config.json 最后落位
/// (commit point;中途崩溃则 pending 目录保留,下次启动幂等重放)。
@MainActor
enum ConfigPorter {
    private static let logger = Logger(subsystem: "opendeck", category: "config-porter")
    static let pendingImportDirName = "pending-import"

    // MARK: - 导出

    struct ExportReport: Equatable {
        var pluginCount: Int
        var settingsDocumentCount: Int
        var iconFileCount: Int
    }

    /// 导出整机备份到 zip(destination 由 SavePanel 提供)。
    /// 配置直接编码内存真相(磁盘文件可能在防抖窗口内滞后);settings 取内存文档副本。
    static func exportConfig(
        to destination: URL,
        config: ConfigStore,
        pluginHost: PluginHostModel,
        iconsBase: URL? = nil // 测试注入;生产 = appSupportRoot
    ) throws -> ExportReport {
        let fileManager = FileManager.default
        let iconsRoot = iconsBase ?? appSupportRoot
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("opendeck-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var pluginCount = 0
        var iconFileCount = 0

        // 1. config.json(内存真相;schemaVersion 由 normalize 持久化的值兜底)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config.config).write(to: staging.appendingPathComponent("config.json"))

        // 2. pluginSettings/
        let documents = pluginHost.exportSettingsDocuments()
        if !documents.isEmpty {
            let dir = staging.appendingPathComponent("pluginSettings", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            for (pluginUUID, document) in documents {
                let data = try JSONEncoder().encode(document)
                try data.write(to: dir.appendingPathComponent("\(pluginUUID).json"), options: .atomic)
            }
        }

        // 3. plugins/(整目录拷贝;缺失的目录跳过并记日志——按理不会发生)
        let pluginsDir = staging.appendingPathComponent("plugins", isDirectory: true)
        for installed in pluginHost.installedPlugins {
            let target = pluginsDir.appendingPathComponent(installed.directoryURL.lastPathComponent, isDirectory: true)
            try fileManager.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            try fileManager.copyItem(at: installed.directoryURL, to: target)
            pluginCount += 1
        }

        // 4. key-icons/ app-icons/(存在才打包)
        for name in ["key-icons", "app-icons"] {
            let source = iconsRoot.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: staging.appendingPathComponent(name, isDirectory: true))
            if let entries = try? fileManager.contentsOfDirectory(atPath: source.path) {
                iconFileCount += entries.count
            }
        }

        // 5. backup.json 元数据(导入侧校验与用户辨识)
        let meta: [String: String] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "schemaVersion": String(config.config.schemaVersion ?? 2),
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("backup.json"))

        // 打包:cwd 设为 staging 使 zip 根 = 暂存内容(config.json 在包根)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.currentDirectoryURL = staging
        process.arguments = ["-c", "-k", ".", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PorterError.dittoFailed("export exit=\(process.terminationStatus)")
        }
        let report = ExportReport(
            pluginCount: pluginCount,
            settingsDocumentCount: documents.count,
            iconFileCount: iconFileCount
        )
        logger.info("备份已导出:\(destination.path, privacy: .public) 插件=\(pluginCount) 参数文档=\(documents.count)")
        return report
    }

    // MARK: - 导入(校验 + 暂存)

    struct ImportSummary: Equatable {
        var sceneCount: Int
        var keyCount: Int
        var pluginCount: Int
        var settingsDocumentCount: Int
        var skippedSettingsFiles: Int
    }

    enum PorterError: LocalizedError, Equatable {
        case dittoFailed(String)
        case missingConfig
        case undecodableConfig(String)
        case newerSchema(Int)

        var errorDescription: String? {
            switch self {
            case .dittoFailed(let detail): "备份包处理失败(ditto):\(detail)"
            case .missingConfig: "备份包里没有 config.json(不是 OpenDeck 备份?)"
            case .undecodableConfig(let detail): "备份包里的 config.json 无法解析:\(detail)"
            case .newerSchema(let version): "备份来自更新版本的 OpenDeck(schema v\(version) > v2),当前版本无法读取"
            }
        }
    }

    /// 校验并暂存导入:zip 解包 → config 可解码 + schema 不超前 → 有效内容拷入
    /// pending-import/。只动暂存目录,对运行中的实例零影响;取消时删除暂存即可。
    /// - Parameter pendingRoot: 暂存根(测试注入;生产 = appSupportRoot)
    static func validateAndStageImport(from archive: URL, pendingRoot: URL? = nil) throws -> ImportSummary {
        let fileManager = FileManager.default
        let extract = fileManager.temporaryDirectory
            .appendingPathComponent("opendeck-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extract, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: extract) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.currentDirectoryURL = extract
        unzip.arguments = ["-x", "-k", archive.path, "."]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw PorterError.dittoFailed("import exit=\(unzip.terminationStatus)")
        }

        // config.json 必须存在且可解码;schema 超前拒绝(旧版读新版 = 未知枚举与迁移盲区)
        let configURL = extract.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path) else { throw PorterError.missingConfig }
        let configData = try Data(contentsOf: configURL)
        let imported: AppConfig
        do {
            imported = try JSONDecoder().decode(AppConfig.self, from: configData)
        } catch {
            throw PorterError.undecodableConfig(error.localizedDescription)
        }
        if let version = imported.schemaVersion, version > 2 {
            throw PorterError.newerSchema(version)
        }

        // 暂存(先清旧暂存:上次取消/失败的残留)
        let pending = (pendingRoot ?? appSupportRoot).appendingPathComponent(pendingImportDirName, isDirectory: true)
        try? fileManager.removeItem(at: pending)
        try fileManager.createDirectory(at: pending, withIntermediateDirectories: true)

        var summary = ImportSummary(sceneCount: imported.scenes.count, keyCount: 0, pluginCount: 0, settingsDocumentCount: 0, skippedSettingsFiles: 0)
        for scene in imported.scenes { summary.keyCount += scene.pages.reduce(0) { $0 + $1.keys.count } }

        try fileManager.copyItem(at: configURL, to: pending.appendingPathComponent("config.json"))

        // pluginSettings:逐文件校验,坏文件跳过计数(不因一个坏文档放弃整包)
        let settingsSource = extract.appendingPathComponent("pluginSettings", isDirectory: true)
        if fileManager.fileExists(atPath: settingsSource.path) {
            let target = pending.appendingPathComponent("pluginSettings", isDirectory: true)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            for entry in try fileManager.contentsOfDirectory(at: settingsSource, includingPropertiesForKeys: nil) {
                guard entry.pathExtension == "json" else { continue }
                guard let data = try? Data(contentsOf: entry),
                      (try? JSONDecoder().decode(PluginSettingsDocument.self, from: data)) != nil
                else {
                    summary.skippedSettingsFiles += 1
                    continue
                }
                try fileManager.copyItem(at: entry, to: target.appendingPathComponent(entry.lastPathComponent))
                summary.settingsDocumentCount += 1
            }
        }

        // plugins / icons:整目录存在才搬运
        for name in ["plugins", "key-icons", "app-icons"] {
            let source = extract.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: pending.appendingPathComponent(name, isDirectory: true))
            if name == "plugins" {
                summary.pluginCount = (try? fileManager.contentsOfDirectory(atPath: source.path).count) ?? 0
            }
        }
        logger.info("导入已暂存:场景=\(summary.sceneCount) 键=\(summary.keyCount) 插件=\(summary.pluginCount) 参数文档=\(summary.settingsDocumentCount)")
        return summary
    }

    /// 用户取消:清掉暂存,回到现状
    static func cancelPendingImport() {
        try? FileManager.default.removeItem(at: pendingImportDirectory)
    }

    // MARK: - 启动应用(pending → 生效)

    /// 应用暂存导入。顺序:settings/icons/plugins 先行,config.json 最后(commit point)——
    /// 中途崩溃时 pending 保留,下次启动幂等重放;config 落位后才删暂存。
    /// 返回是否应用了导入(调用方记日志)。
    @discardableResult
    static func applyPendingImport(appSupport: URL) -> Bool {
        let fileManager = FileManager.default
        let pending = appSupport.appendingPathComponent(pendingImportDirName, isDirectory: true)
        guard fileManager.fileExists(atPath: pending.path) else { return false }
        logger.info("发现待应用配置备份,开始替换…")

        func replaceDirectory(_ name: String) throws {
            let source = pending.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { return } // 备份没有 = 保留现状
            let target = appSupport.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: source, to: target)
        }

        do {
            try replaceDirectory("pluginSettings")
            try replaceDirectory("plugins")
            try replaceDirectory("key-icons")
            try replaceDirectory("app-icons")
            let configTarget = appSupport.appendingPathComponent("config.json")
            if fileManager.fileExists(atPath: configTarget.path) {
                try fileManager.removeItem(at: configTarget)
            }
            try fileManager.moveItem(at: pending.appendingPathComponent("config.json"), to: configTarget)
            try fileManager.removeItem(at: pending)
            logger.info("配置备份已应用,本次启动即导入后的世界")
            return true
        } catch {
            // pending 保留:下次启动重放幂等;config.json 已换而 plugins 未换的组合可接受
            // (插件缺失键帽显示「插件未安装」警示,配置主体无恙)
            logger.fault("应用配置备份失败(pending 保留,下次启动重试):\(error, privacy: .public)")
            return false
        }
    }

    /// 用户确认后自重启:延迟 2s 再 open(让旧实例先退干净,否则单实例锁会拦新实例)
    static func relaunchAfterPendingImport() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            logger.info("非 .app 形态(开发直跑),不自动重启;请手动重新打开")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; open \"\(Bundle.main.bundleURL.path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }

    static var appSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenDeck", isDirectory: true)
    }

    static var pendingImportDirectory: URL {
        appSupportRoot.appendingPathComponent(pendingImportDirName, isDirectory: true)
    }
}
