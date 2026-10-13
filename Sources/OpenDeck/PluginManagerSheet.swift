import PluginHost
import SwiftUI
import UniformTypeIdentifiers

/// 插件管理器:本地插件库的列表/安装/官方导入/卸载。
/// 安装 = 校验 manifest 后整目录拷贝进插件根(来源不动);卸载 = 移废纸篓。
struct PluginManagerSheet: View {
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var busyMessage: String?
    @State private var importSummary: String?
    @State private var uninstallTarget: InstalledPlugin?

    private var host: PluginHostModel { appModel.pluginHost }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(host.installedPlugins, id: \.manifest.pluginUUID) { plugin in
                        row(plugin)
                    }
                    if host.installedPlugins.isEmpty {
                        Text("插件库为空。点右上角「安装…」选择 .sdPlugin 目录或 .streamDeckPlugin 文件,或一键导入官方已装插件。")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("已安装(\(host.installedPlugins.count))")
                } footer: {
                    if !host.brokenPlugins.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(host.brokenPlugins, id: \.self) { line in
                                Text("⚠️ \(line)").font(.caption)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                if let importSummary {
                    Text(importSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("从官方导入") { importFromOfficial() }
                    .disabled(busyMessage != nil)
                Button("安装…") { installViaPanel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busyMessage != nil)
                Button("完成") { dismiss() }
            }
            .padding(12)
        }
        .frame(width: 560, height: 420)
        .overlay {
            if let busyMessage {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(busyMessage)
                        .font(.callout)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func row(_ plugin: InstalledPlugin) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(host.isRunning(pluginUUID: plugin.manifest.pluginUUID) ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
                .help(host.isRunning(pluginUUID: plugin.manifest.pluginUUID) ? "运行中" : "未运行(分配到键后拉起)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.manifest.name).font(.body.weight(.semibold))
                    Text("v\(plugin.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !plugin.manifest.family.isNode {
                        Text("HTML·暂不支持")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: Capsule())
                    }
                }
                Text("\(plugin.manifest.pluginUUID) · \(plugin.manifest.keypadActions.count) 个动作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if plugin.manifest.family.isNode {
                Button(role: .destructive) {
                    uninstallTarget = plugin
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("卸载(移入废纸篓)")
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "卸载 \(uninstallTarget?.manifest.name ?? "")?其设置文件一并删除,已分配的按键动作将失效。",
            isPresented: Binding(get: { uninstallTarget != nil }, set: { if !$0 { uninstallTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("移入废纸篓", role: .destructive) {
                if let target = uninstallTarget { uninstall(target) }
                uninstallTarget = nil
            }
            Button("取消", role: .cancel) { uninstallTarget = nil }
        }
    }

    // MARK: - 操作

    private func installViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item] // .sdPlugin 目录与 .streamDeckPlugin 文件混选
        panel.prompt = "安装"
        panel.message = "选择 .sdPlugin 插件目录或 .streamDeckPlugin 包"
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        busyMessage = "正在安装…"
        Task {
            defer { busyMessage = nil }
            do {
                let manifest = try host.installPlugin(from: url)
                importSummary = "已安装 \(manifest.name) v\(manifest.version)"
            } catch {
                importSummary = "安装失败:\(String(describing: error))"
            }
        }
    }

    private func importFromOfficial() {
        busyMessage = "正在从官方 StreamDock 导入插件…"
        Task {
            defer { busyMessage = nil }
            let results = host.importFromOfficialApp()
            if results.isEmpty {
                importSummary = "官方目录没有可导入的 Node 插件"
            } else {
                let failed = results.filter { $0.error != nil }
                importSummary = failed.isEmpty
                    ? "已导入 \(results.count) 个插件:\(results.map(\.name).joined(separator: ", "))"
                    : "导入 \(results.count) 个,失败 \(failed.count):\(failed.map(\.name).joined(separator: ", "))"
            }
        }
    }

    private func uninstall(_ plugin: InstalledPlugin) {
        do {
            try host.uninstallPlugin(id: plugin.manifest.pluginUUID)
            importSummary = "已卸载 \(plugin.manifest.name)"
        } catch {
            importSummary = "卸载失败:\(String(describing: error))"
        }
    }
}
